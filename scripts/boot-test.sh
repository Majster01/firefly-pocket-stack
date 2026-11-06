#!/usr/bin/env bash
#
# Boot the whole stack from scratch with throwaway values, the way a new server
# is set up (README "Configure" and "Bootstrap"), and check it with the
# deploy's own smoke test. CI runs it on every PR (Release pipeline step 4), so
# a change that would leave the server unable to start fails its PR instead.
#
#     scripts/boot-test.sh            # boots, checks, then removes everything it made
#     KEEP=1 scripts/boot-test.sh     # leaves the stack running to look at
#
# Needs Docker and nothing else, and never runs where a compose/.env already
# exists: it makes its own, and its containers, volumes and networks use the
# server's names.
#
#   1. the settings as a new server makes them (README "Configure"): DOMAIN=localhost,
#      the two emails and nothing else set by hand, every secret from gen-secrets.sh,
#      and compose/.env written from that store. No hostname of its own, so every
#      host is derived (*.localhost, which Caddy serves from its own CA)
#   2. Postgres and Firefly III, until Firefly III answers
#   3. the first user and a Personal Access Token, as stage 2 needs, without
#      the web UI; the token goes into IMPORTER_FIREFLY_TOKEN and
#      SUGGESTER_FIREFLY_TOKEN, with config set
#   4. everything, as the deploy starts it: up -d --no-build --remove-orphans
#   5. the deploy's smoke test, and the token against Firefly III's API and
#      through Firefly Pocket's, which calls Firefly III on the internal network
#   6. the legal pages through Caddy: on their host, and under /legal/ on
#      Firefly Pocket's; and a bank consent's callback reaching the importer
#      fork on Firefly Pocket's host and on the importer's

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/compose/.env"
STORE=(compose/config.json compose/secrets/env compose/.env.rendered)
cd "$REPO_ROOT"

if [ -f "$ENV_FILE" ] || [ -e compose/config.json ] || [ -e compose/secrets/env ]; then
  echo "FATAL: $ENV_FILE or the settings store exists. This boots a throwaway stack under the server's names;" >&2
  echo "       run it in a fresh checkout, never on the server." >&2
  exit 1
fi
if [ -n "$(docker ps -aq --filter name=^fireflyx-)" ]; then
  echo "FATAL: containers named fireflyx-* exist already; this would collide with them." >&2
  exit 1
fi

compose() { docker compose --project-directory "$REPO_ROOT/compose" "$@"; }

# Every exit: on a failure, what each service said; then remove all of it.
finish() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    echo "==> FAILED (exit $status). Services:"
    compose ps -a || true
    for svc in $(compose config --services 2>/dev/null); do
      echo "---------------------------------------------------------------- $svc"
      compose logs --no-log-prefix --tail 60 "$svc" 2>&1 || true
    done
  fi
  if [ "${KEEP:-}" = 1 ]; then
    echo "==> KEEP=1: still running. Remove it with: docker compose --project-directory compose down -v; rm -r compose/.env ${STORE[*]}"
  else
    compose down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$ENV_FILE" "${STORE[@]}"
  fi
  exit "$status"
}
trap finish EXIT

# setting KEY VALUE: as a person sets one, the value through stdin.
setting() { scripts/firefly-pocket config set "$1" - <<<"$2" >/dev/null; }

echo "==> the settings, as a new server makes them, with throwaway values"
setting DOMAIN localhost
setting ACME_EMAIL ci@example.com
setting SITE_OWNER ci@example.com
scripts/gen-secrets.sh >/dev/null
if grep -E '^[A-Z_]+_HOSTNAME=' "$ENV_FILE"; then
  echo "FATAL: a new server should need only DOMAIN, but compose/.env sets the hostnames above" >&2
  exit 1
fi

# lib.sh reads compose/.env, so it comes after it.
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"

echo "==> Postgres and Firefly III"
compose up -d --no-build db app
for _ in $(seq 60); do
  internal_http http://app:8080/health 10 >/dev/null 2>&1 && break
  sleep 5
done
internal_http http://app:8080/health 10 >/dev/null || { echo "Firefly III did not answer within five minutes"; exit 1; }

echo "==> the first user and a Personal Access Token"
# Firefly's own system:create-first-user, which also fires its new-user event.
# It refuses outside the testing environment, so the check is flipped for this
# one process only. Its log goes to stdout too: the token is the last line.
token="$(compose exec -T app php <<'PHP' | tail -n 1
<?php
require 'vendor/autoload.php';
$app = require 'bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
use Illuminate\Support\Facades\Artisan;
config(['app.env' => 'testing']);
foreach ([
    ['system:create-first-user', ['email' => 'ci@example.com']],
    ['passport:client', ['--personal' => true, '--name' => 'boot-test', '--no-interaction' => true]],
] as [$command, $arguments]) {
    if (Artisan::call($command, $arguments) !== 0) {
        fwrite(STDERR, "$command failed:\n" . Artisan::output());
        exit(1);
    }
}
echo "\n", FireflyIII\User::firstOrFail()->createToken('boot-test')->accessToken, "\n";
PHP
)"
if ! [[ "$token" =~ ^[A-Za-z0-9._-]{100,}$ ]]; then
  echo "no token from Firefly III; its last line was: ${token:0:200}"
  exit 1
fi
setting IMPORTER_FIREFLY_TOKEN "$token"
setting SUGGESTER_FIREFLY_TOKEN "$token"

echo "==> everything, as the deploy starts it"
compose up -d --no-build --remove-orphans

echo "==> the deploy's smoke test"
smoke_test

echo "==> the token against Firefly III's API, and through Firefly Pocket's"
token_check "$token"

# By name through Caddy, as a browser asks: its own CA for *.localhost (-k),
# from this network. The legal pages render on their host and under /legal/
# on Firefly Pocket's, and the rest of that host is still the app.
echo "==> the legal pages through Caddy, on both hosts"
through_caddy() {
  docker run --rm --network "$DOCKER_NETWORK" "$CURL_IMAGE" \
    -fsS -k -L --max-time 30 --connect-to ::caddy:443 "$1"
}
for url in "https://$LEGAL_HOSTNAME/" "https://$LEGAL_HOSTNAME/privacy" "https://$LEGAL_HOSTNAME/terms" \
           "https://$NEXT_HOSTNAME/legal" "https://$NEXT_HOSTNAME/legal/privacy" "https://$NEXT_HOSTNAME/legal/terms"; do
  page="$(through_caddy "$url")" || { echo "no page at $url"; exit 1; }
  if [[ "$page" != *"</html>"* || "$page" == *"{{"* || "$page" == *'type="module"'* ]]; then
    echo "not a rendered legal page at $url:"
    head -c 400 <<<"$page"
    exit 1
  fi
done
[[ "$(through_caddy "https://$NEXT_HOSTNAME/")" == *'type="module"'* ]] || { echo "the app is not at https://$NEXT_HOSTNAME/"; exit 1; }
echo "the legal pages render on both hosts, and the app is still the app"

# A bank consent coming back, with a state the fork never handed out: the
# fork refuses it by sending the browser to Firefly Pocket's bank page. That
# redirect, and not Pocket's own page, proves Caddy routed it to the fork. On
# Pocket's host, where links from Firefly Pocket now come back, and on the
# importer's, which still works until Hostnames and routing step 8.
echo "==> a bank consent coming back reaches the importer fork, on both hosts"
for host in "$NEXT_HOSTNAME" "$IMPORT_HOSTNAME"; do
  went="$(docker run --rm --network "$DOCKER_NETWORK" "$CURL_IMAGE" -sS -k --max-time 30 \
    --connect-to ::caddy:443 -o /dev/null -w '%{http_code} %{redirect_url}' \
    "https://$host/eb-callback?state=fx-0123456789abcdef&code=boot-test")"
  if [[ "$went" != "302 https://$NEXT_HOSTNAME/bank-connections"*"reason=invalid_state"* ]]; then
    echo "https://$host/eb-callback did not reach the importer fork: $went"
    exit 1
  fi
done
echo "the fork answered the callback on both hosts"

echo "==> booted and checked"
