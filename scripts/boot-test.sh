#!/usr/bin/env bash
#
# Boot the whole stack from scratch with throwaway values, the way a new server
# is set up (README "Set it up"), and check it with the
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
#   1. scripts/firefly-pocket setup, as a new server runs it (README "Set it up"),
#      its answers piped in: DOMAIN=localhost, an email and a password, every
#      optional step skipped, the deploy agent off. That sets no hostname, so each
#      is derived (*.localhost, which Caddy serves from its own CA); the secrets come
#      from gen-secrets.sh, and compose/.env is written from the settings store
#   2. its account step: Postgres and Firefly III only, then the account and one
#      token per app, made inside Firefly III by scripts/firefly-bootstrap.php, and
#      /register closed. So every new Firefly III image runs that script here
#      before its bump merges: it uses Firefly III's internal classes
#   3. its start step: everything, as the deploy starts it (up -d --no-build
#      --remove-orphans), and the deploy's smoke test
#   4. the account step again, with no input: it must ask nothing and keep every token
#   5. each token against Firefly III's API and through Firefly Pocket's, which
#      calls Firefly III on the internal network
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

# A bounded read, as gen-secrets.sh makes its secrets.
password="$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(LC_ALL=C head -c 512 /dev/urandom))"
password="${password:0:24}"
# One line per question, in the wizard's order. A question it did not ask
# before shifts every answer after it, and the run fails.
answers=(
  localhost        # Domain
  ci@example.com   # Email
  ''               # Name, for the legal pages: none
  ''               # Timezone: this machine's
  ''               # the importer's password, shown once: go on
  "$password"      # Firefly III account: password
  "$password"      # once more
  n                # bank import: not now
  ''               # AI key: none
  none             # ntfy: none
  ''               # healthchecks.io: none
  ''               # restic repository: none
  n                # deploy agent: off, never on a runner
)
echo "==> scripts/firefly-pocket setup, as a new server runs it, with throwaway answers"
printf '%s\n' "${answers[@]}" | scripts/firefly-pocket setup
if grep -E '^[A-Z_]+_HOSTNAME=' "$ENV_FILE"; then
  echo "FATAL: a new server should need only DOMAIN, but compose/.env sets the hostnames above" >&2
  exit 1
fi

# lib.sh reads compose/.env, so it comes after it.
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
tokens=("$IMPORTER_FIREFLY_TOKEN" "$SUGGESTER_FIREFLY_TOKEN" "$NEXT_WARMUP_FIREFLY_TOKEN")
if [ "$(printf '%s\n' "${tokens[@]}" | sort -u | wc -l)" -ne 3 ]; then
  echo "FATAL: the three apps should have a token each" >&2
  exit 1
fi

echo "==> setup account again, with nothing to answer: it keeps every token"
scripts/firefly-pocket setup account </dev/null
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
if [ "$IMPORTER_FIREFLY_TOKEN $SUGGESTER_FIREFLY_TOKEN $NEXT_WARMUP_FIREFLY_TOKEN" != "${tokens[*]}" ]; then
  echo "FATAL: the second run made new tokens" >&2
  exit 1
fi

echo "==> the deploy's smoke test"
smoke_test

echo "==> each app's token against Firefly III's API, and through Firefly Pocket's"
for token in "${tokens[@]}"; do
  token_check "$token"
done

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
