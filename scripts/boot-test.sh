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
#   1. scripts/firefly-pocket setup web, as a new server starts in the browser
#      (README "Set it up"): DOMAIN=localhost and an email piped in. Only Caddy and
#      the console run, and every other name sends the browser to the console
#      (the setup gate), Firefly III's /register included
#   2. the console through Caddy: it asks for the setup code, refuses a wrong one
#      and a form from another origin, takes the right one, shows the names, refuses
#      a bad timezone, and hands a good save to scripts/console.sh, which applies it.
#      Requests a compromised console could write are refused, and change nothing
#   3. scripts/firefly-pocket setup, as a new server runs it next, its answers
#      piped in: Enter for what the console saved, a password, every optional step
#      skipped, the deploy agent off. That sets no hostname, so each is derived
#      (*.localhost, which Caddy serves from its own CA); the secrets come from
#      gen-secrets.sh, and compose/.env is written from the settings store
#   4. its account step: Postgres and Firefly III only, then the account and one
#      token per app, made inside Firefly III by scripts/firefly-bootstrap.php, and
#      /register closed. So every new Firefly III image runs that script here
#      before its bump merges: it uses Firefly III's internal classes
#   5. its start step: everything, as the deploy starts it (up -d --no-build
#      --remove-orphans), and the deploy's smoke test. The gate opens: the console
#      says setup is finished, and the code and the agent refuse to change anything
#   6. the account step again, with no input: it must ask nothing and keep every token
#   7. each token against Firefly III's API and through Firefly Pocket's, which
#      calls Firefly III on the internal network
#   8. the legal pages through Caddy: on their host, and under /legal/ on
#      Firefly Pocket's; and a bank consent's callback reaching the importer
#      fork on Firefly Pocket's host and on the importer's

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/compose/.env"
STORE=(compose/config.json compose/secrets/env compose/.env.rendered compose/console)
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
  rm -rf "$jar"
  exit "$status"
}
jar="$(mktemp -d)"
trap finish EXIT
fail() { echo "FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------- in the browser ---
# One line per question, in the wizard's order. A question it did not ask
# before shifts every answer after it, and the run fails.
web_answers=(
  localhost        # Domain
  ci@example.com   # Email
  ''               # the importer's password, shown once: go on
)
echo "==> scripts/firefly-pocket setup web, as a new server starts in the browser"
printf '%s\n' "${web_answers[@]}" | FIREFLY_POCKET_NO_SYSTEMD=1 scripts/firefly-pocket setup web
# lib.sh reads compose/.env, so it comes after it.
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
running="$(compose ps --status running --services | sort | paste -sd' ' -)"
[ "$running" = "caddy console" ] || fail "setup web should start Caddy and the console only, but runs: $running"

echo "==> every other name shows only the console"
for url in "https://$FIREFLY_HOSTNAME/register" "https://$NEXT_HOSTNAME/" "https://$NEXT_HOSTNAME/legal/privacy" \
           "https://$NEXT_HOSTNAME/eb-callback?state=fx-0123456789abcdef&code=boot-test" \
           "https://$IMPORT_HOSTNAME/" "https://$LEGAL_HOSTNAME/terms"; do
  went="$(docker run --rm --network "$DOCKER_NETWORK" "$CURL_IMAGE" -sS -k --max-time 30 \
    --connect-to ::caddy:443 -o /dev/null -w '%{http_code} %{redirect_url}' "$url")"
  [ "$went" = "302 https://$ADMIN_HOSTNAME/" ] || fail "$url answered \"$went\", not a redirect to the console"
done
echo "each of the four sends the browser to https://$ADMIN_HOSTNAME/"

# The console as a browser reaches it: through Caddy, on the port it publishes,
# keeping its cookie. Its own CA for *.localhost (-k).
ask_console() {
  curl -sS -k --max-time 60 --resolve "$ADMIN_HOSTNAME:443:127.0.0.1" -b "$jar/cookies" -c "$jar/cookies" "$@"
}
here=(-H "Origin: https://$ADMIN_HOSTNAME")
admin="https://$ADMIN_HOSTNAME"

echo "==> the console asks for the setup code"
[[ "$(ask_console "$admin/")" == *'name="code"'* ]] || fail "the console does not ask for the setup code"
went="$(ask_console "${here[@]}" -o /dev/null -w '%{http_code}' --data-urlencode code=0000-0000-0000-0000 "$admin/login")"
[ "$went" = 401 ] || fail "a wrong code got $went"
went="$(ask_console -H 'Origin: https://elsewhere.example' -o /dev/null -w '%{http_code}' --data-urlencode "code=$SETUP_CODE" "$admin/login")"
[ "$went" = 403 ] || fail "a sign-in from another origin got $went"
went="$(ask_console "${here[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' --data-urlencode "code=$SETUP_CODE" "$admin/login")"
[ "$went" = "303 $admin/server" ] || fail "the right code got \"$went\""
page="$(ask_console "$admin/server")"
for want in 'value="localhost"' 'value="ci@example.com"' "$ADMIN_HOSTNAME" "$FIREFLY_HOSTNAME" "this machine"; do
  [[ "$page" == *"$want"* ]] || fail "the console's server page has no $want"
done
echo "a wrong code and another origin are refused; the right code shows the server page"

echo "==> a save goes to the server, which checks it again and applies it"
save() {
  ask_console "${here[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' --data domain=localhost \
    --data-urlencode email=ci@example.com --data-urlencode "name=$1" --data-urlencode "timezone=$2" "$admin/server"
}
went="$(save '' Mars/Base)"
[ "$went" = "400 " ] || fail "a bad timezone got \"$went\""
went="$(save 'CI Operator' Europe/Ljubljana)"
[[ "$went" =~ ^303\ ($admin/requests/[0-9a-f]{32})$ ]] || fail "a good save got \"$went\""
request="${BASH_REMATCH[1]}"
inbox=compose/console/inbox
[ "$(find "$inbox" -name '*.json' | wc -l)" -eq 1 ] || fail "the inbox should hold the one request"
# What a compromised console could write instead: a bad value, a setting it has
# no say in, and a link to a file of the server's.
fake_id() { local s; s="$(printf '%32s' '')"; printf '%s' "${s// /$1}"; }
state() { jq -r --arg id "$1" '.requests[$id].state // "none"' compose/console/status/status.json; }
printf '{"action":"server","settings":{"DOMAIN":"localhost","SITE_OWNER":"ci@example.com","LEGAL_OWNER_NAME":"","TZ":"Mars/Base"}}' \
  > "$inbox/$(fake_id a).json"
printf '{"action":"server","settings":{"IMPORTER_FIREFLY_TOKEN":"x"}}' > "$inbox/$(fake_id b).json"
ln -s ../../config.json "$inbox/$(fake_id c).json"
scripts/firefly-pocket console apply
[ -z "$(ls -A "$inbox")" ] || fail "console apply left requests in the inbox: $(ls -A "$inbox")"
[ "$(scripts/firefly-pocket config get LEGAL_OWNER_NAME)" = "CI Operator" ] || fail "the name was not saved"
[ "$(scripts/firefly-pocket config get TZ)" = Europe/Ljubljana ] || fail "the timezone was not saved"
scripts/firefly-pocket config has IMPORTER_FIREFLY_TOKEN && fail "a request set the importer's token"
[ "$(state "${request##*/}")" = applied ] || fail "the console's request: $(state "${request##*/}"), not applied"
for forged in a b c; do
  [ "$(state "$(fake_id $forged)")" = refused ] || fail "the forged request $(fake_id $forged): $(state "$(fake_id $forged)"), not refused"
done
# Caddy starts again with the new name: give it a moment.
for _ in $(seq 15); do
  page="$(ask_console "$request" || true)"
  [[ "$page" == *"Saved: your name and the timezone."* ]] && break
  sleep 2
done
[[ "$page" == *"Saved: your name and the timezone."* ]] || fail "the console does not say the save was applied"
echo "applied, and the forged requests refused"

# ----------------------------------------------------------- over SSH ---
# A bounded read, as gen-secrets.sh makes its secrets.
password="$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(LC_ALL=C head -c 512 /dev/urandom))"
password="${password:0:24}"
answers=(
  ''               # Domain: localhost, from setup web
  ''               # Email: ci@example.com, from setup web
  ''               # Name: CI Operator, saved in the console
  ''               # Timezone: Europe/Ljubljana, saved in the console
  "$password"      # Firefly III account: password
  "$password"      # once more
  n                # bank import: not now
  ''               # AI key: none
  none             # ntfy: none
  ''               # healthchecks.io: none
  ''               # restic repository: none
  n                # deploy agent: off, never on a runner
)
echo "==> scripts/firefly-pocket setup, as a new server runs it next, with throwaway answers"
printf '%s\n' "${answers[@]}" | scripts/firefly-pocket setup
if grep -E '^[A-Z_]+_HOSTNAME=' "$ENV_FILE"; then
  fail "a new server should need only DOMAIN, but compose/.env sets the hostnames above"
fi
[ "$(scripts/firefly-pocket config get LEGAL_OWNER_NAME)" = "CI Operator" ] || fail "Enter did not keep the name"

# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"

echo "==> setup is finished: the gate is open, and the console changes nothing"
page="$(ask_console "$admin/")"
[[ "$page" == *"Setup is finished"* ]] || fail "the console does not say setup is finished"
headers="$(ask_console "${here[@]}" -o /dev/null -D - --data-urlencode "code=$SETUP_CODE" "$admin/login")"
grep -qi '^set-cookie:' <<<"$headers" && fail "the setup code still signs in"
printf '{"action":"server","settings":{"DOMAIN":"localhost","SITE_OWNER":"ci@example.com","LEGAL_OWNER_NAME":"","TZ":"Etc/UTC"}}' \
  > "$inbox/$(fake_id d).json"
scripts/firefly-pocket console apply
[ "$(state "$(fake_id d)")" = refused ] || fail "the agent applied a request after setup: $(state "$(fake_id d)")"
[ "$(scripts/firefly-pocket config get TZ)" = Europe/Ljubljana ] || fail "the timezone changed after setup"
echo "the code no longer signs in, and the agent refused a request"
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
