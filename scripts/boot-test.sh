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
# Needs Docker and restic (cloud-init installs it on a server), and never runs
# where a compose/.env already exists: it makes its own, and its containers, volumes and networks use the
# server's names.
#
#   1. scripts/firefly-pocket setup web, as a new server starts in the browser
#      (README "Set it up"): DOMAIN=localhost and an email piped in. Only Caddy and
#      the console run, and every other name sends the browser to the console
#      (the setup gate), Firefly III's /register included
#   2. the console through Caddy: it asks for the setup code, refuses a wrong one
#      and a form from another origin, takes the right one, shows the names, refuses
#      a bad timezone, and hands a good save to scripts/console.sh, which applies it.
#      Requests a compromised console could write are refused, and change nothing,
#      as is one without the setup code, which any user of the server could write
#   3. the console's account step: two passwords that differ are refused, then the
#      server makes the account from what the console sends (console apply, in the
#      background, while the console shows how far it got): every image pulled,
#      Postgres and Firefly III only, then the account and one token per app, made
#      inside Firefly III by scripts/firefly-bootstrap.php, /register closed, and
#      everything started, as the deploy starts it (up -d --no-build
#      --remove-orphans), with the deploy's smoke test. So every new Firefly III
#      image runs that script here before its bump merges: it uses Firefly III's
#      internal classes. The gate opens, the password is in no file, and the
#      console's session lasts: making the account does not start it again
#   4. the console's bank step: the server makes a key and its certificate, which
#      the console hands out, and keeps an application ID once Enable Banking takes
#      a request signed with the key for it. Stand-ins for the services setup
#      talks to answer here on the runner; Enable Banking's checks each request's
#      signature with that certificate, so a wrong ID is refused and the right one
#      kept, and the importer starts again with it. Steps the console has done are
#      refused now
#   5. the console's suggestions and alerts steps: a wrong AI key refused and the
#      right one kept, an ntfy topic kept once a test alert reaches it, and
#      healthchecks.io's two checks made, in the server's timezone, with an API key
#      that is not kept. No key is in a file the console reaches. Then backups: a
#      restic repository on the runner, made with the password the console shows
#      once, which opens it; an empty place refused as an existing repository, a
#      wrong password refused, the right one kept. The password is in no file the
#      console reaches. Then updates, with stand-ins for sudo and systemctl, as a
#      runner's own would start the deploy agent here: refused without sudo that
#      needs no password, then the deploy timer's units written for this checkout
#      and the timer enabled
#   6. the console's Finish: the setup code goes, the console starts again without
#      it, and the code signs in no more
#   7. scripts/firefly-pocket setup, as a new server runs it next, its answers
#      piped in: Enter for what the console saved, the bank's ID, the AI key and
#      the repository checked again, the deploy agent off. It must ask no password
#      and keep the console's tokens. That sets no hostname, so each is derived
#      (*.localhost, which Caddy serves from its own CA); the secrets come from
#      gen-secrets.sh, and compose/.env is written from the settings store. The
#      agent refuses a request with the old code
#   8. the account step again, with no input: it must ask nothing and keep every token
#   9. each token against Firefly III's API and through Firefly Pocket's, which
#      calls Firefly III on the internal network. Then the console, setup
#      finished, signs you in with Firefly III, as a browser does: its own login
#      page with the account's password, its approval page, and back to the
#      console, which shows the server to its owner. Signed in, the owner makes a
#      new bank key from the browser: a new certificate, uploaded to Enable
#      Banking's stand-in, and the application ID kept with it; and opens the
#      importer's own pages under /importer/ on the console's host. Sign out
#      leaves Firefly III taking none of the console's tokens, and the importer's
#      pages shut. After setup, a request with no token, the old code, another
#      app's token or a malformed one is refused; and console expire revokes a
#      sign-in made nine hours old. Then Firefly Pocket's own sign-in with
#      Firefly III, as its page does it in a browser: with PKCE, back to its
#      /oauth/callback, and the code swapped by its server for a token that
#      works, once, and only with the browser's verifier. Then the apps' tokens, as the nightly run
#      rotates them: none due with a year left, all three made again when due,
#      the old ones refused, and the importer and Firefly Pocket started again
#      with the new ones
#  10. the legal pages through Caddy: on their host, and under /legal/ on
#      Firefly Pocket's; and a bank consent's callback reaching the importer
#      fork on Firefly Pocket's host and on the importer's. With no sign-in, the
#      importer's pages on the console's host send the browser to the console,
#      the fork's API is not there, and a callback of the importer's own flow on
#      Firefly Pocket's host goes on to them

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
command -v restic >/dev/null 2>&1 || {
  echo "FATAL: restic is not installed (sudo apt-get install -y restic): the backups step needs it, as on a server" >&2
  exit 1
}
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
  [ -z "${stub:-}" ] || kill "$stub" 2>/dev/null || true
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
# What a compromised console could write instead, with the setup code it holds:
# a bad value, a setting it has no say in, a link to a file of the server's, and
# a password Firefly III would refuse. And what any user of the server could
# write: an account without the code.
fake_id() { local s; s="$(printf '%32s' '')"; printf '%s' "${s// /$1}"; }
state() { jq -r --arg id "$1" '.requests[$id].state // "none"' compose/console/status/status.json; }
code="${SETUP_CODE//-/}"
printf '{"action":"server","code":"%s","settings":{"DOMAIN":"localhost","SITE_OWNER":"ci@example.com","LEGAL_OWNER_NAME":"","TZ":"Mars/Base"}}' \
  "$code" > "$inbox/$(fake_id a).json"
printf '{"action":"server","code":"%s","settings":{"IMPORTER_FIREFLY_TOKEN":"x"}}' "$code" > "$inbox/$(fake_id b).json"
ln -s ../../config.json "$inbox/$(fake_id c).json"
printf '{"action":"account","code":"%s","password":"short"}' "$code" > "$inbox/$(fake_id e).json"
printf '{"action":"account","password":"long enough to be taken, but no code"}' > "$inbox/$(fake_id f).json"
scripts/firefly-pocket console apply
[ -z "$(ls -A "$inbox")" ] || fail "console apply left requests in the inbox: $(ls -A "$inbox")"
[ "$(scripts/firefly-pocket config get LEGAL_OWNER_NAME)" = "CI Operator" ] || fail "the name was not saved"
[ "$(scripts/firefly-pocket config get TZ)" = Europe/Ljubljana ] || fail "the timezone was not saved"
scripts/firefly-pocket config has IMPORTER_FIREFLY_TOKEN && fail "a request set the importer's token"
[ "$(state "${request##*/}")" = applied ] || fail "the console's request: $(state "${request##*/}"), not applied"
for forged in a b c e f; do
  [ "$(state "$(fake_id $forged)")" = refused ] || fail "the forged request $(fake_id $forged): $(state "$(fake_id $forged)"), not refused"
done
running="$(compose ps --status running --services | sort | paste -sd' ' -)"
[ "$running" = "caddy console" ] || fail "a refused account request started something: $running"
# Caddy starts again with the new name: give it a moment.
for _ in $(seq 15); do
  page="$(ask_console "$request" || true)"
  [[ "$page" == *"Saved: your name and the timezone."* ]] && break
  sleep 2
done
[[ "$page" == *"Saved: your name and the timezone."* ]] || fail "the console does not say the save was applied"
echo "applied, and the forged requests refused"

echo "==> the console's account step: the server makes the account and a token for each app"
page="$(ask_console "$admin/account")"
[[ "$page" == *'value="ci@example.com"'* && "$page" == *'name="password2"'* ]] || fail "the console's account page asks for no password"
# A bounded read, as gen-secrets.sh makes its secrets.
password="$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(LC_ALL=C head -c 512 /dev/urandom))"
password="${password:0:24}"
account() {
  ask_console "${here[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' \
    --data-urlencode "password=$password" --data-urlencode "password2=$1" "$admin/account"
}
went="$(account "${password}x")"
[ "$went" = "400 " ] || fail "two passwords that differ got \"$went\""
went="$(account "$password")"
[[ "$went" =~ ^303\ ($admin/requests/[0-9a-f]{32})$ ]] || fail "the account got \"$went\""
request="${BASH_REMATCH[1]}"
# As the systemd unit runs it, but in the background, to watch the console
# meanwhile: it says how far the server got, which only the agent knows.
scripts/firefly-pocket console apply > "$jar/apply.log" 2>&1 &
apply=$!
seen=""
while kill -0 "$apply" 2>/dev/null; do
  page="$(ask_console "$request" 2>/dev/null || true)"
  if [[ "$page" == *"Making your account"*"This takes a few minutes."* ]]; then
    seen=1
    break
  fi
  sleep 2
done
status=0
wait "$apply" || status=$?
sed 's/^/   | /' "$jar/apply.log"
[ "$status" -eq 0 ] || fail "console apply failed (exit $status)"
[ -n "$seen" ] || fail "the console never showed how far the server got"
[ "$(state "${request##*/}")" = applied ] || fail "the account request: $(state "${request##*/}"): $(jq -r --arg id "${request##*/}" '.requests[$id].message' compose/console/status/status.json)"
if grep -rqF -- "$password" compose "$jar"; then
  fail "the password is in a file: $(grep -rlF -- "$password" compose "$jar" | paste -sd' ' -)"
fi
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
made=("$IMPORTER_FIREFLY_TOKEN" "$SUGGESTER_FIREFLY_TOKEN" "$NEXT_WARMUP_FIREFLY_TOKEN")
for token in "${made[@]}"; do
  token_check "$token"
done
# The same session goes on to the bank step: the console did not start again.
# Caddy did, with the gate open: give it a moment.
for _ in $(seq 30); do
  went="$(ask_console -o /dev/null -w '%{http_code} %{redirect_url}' "$admin/" 2>/dev/null || true)"
  [ "$went" = "303 $admin/bank" ] && break
  sleep 2
done
[ "$went" = "303 $admin/bank" ] || fail "once the account is made, the console's session should go on to the bank step, but got \"$went\""
page="$(docker run --rm --network "$DOCKER_NETWORK" "$CURL_IMAGE" -fsS -k -L --max-time 30 \
  --connect-to ::caddy:443 "https://$NEXT_HOSTNAME/")" || fail "no page at https://$NEXT_HOSTNAME/ once the account was made"
[[ "$page" == *'type="module"'* ]] || fail "https://$NEXT_HOSTNAME/ is not the app once the account was made"
echo "the account and a token per app are made, the gate is open, the password is in no file, and the session lasts"

echo "==> the console's bank step: a key made on the server, and an application ID checked with it"
# Steps done are done, and nothing goes without the code.
printf '{"action":"server","code":"%s","settings":{"DOMAIN":"localhost","SITE_OWNER":"ci@example.com","LEGAL_OWNER_NAME":"","TZ":"Etc/UTC"}}' \
  "$code" > "$inbox/$(fake_id 1).json"
printf '{"action":"account","code":"%s","password":"long enough to be taken, and the code"}' "$code" > "$inbox/$(fake_id 2).json"
printf '{"action":"bank_key"}' > "$inbox/$(fake_id 3).json"
scripts/firefly-pocket console apply
for forged in 1 2 3; do
  [ "$(state "$(fake_id $forged)")" = refused ] || fail "the request $(fake_id $forged): $(state "$(fake_id $forged)"), not refused"
done
scripts/firefly-pocket config has ENABLE_BANKING_PRIVATE_KEY && fail "a request without the code made a key"
[[ "$(ask_console "$admin/bank")" == *'action="/bank/key"'* ]] || fail "the bank page offers no key"
went="$(ask_console "${here[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' --data '' "$admin/bank/key")"
[[ "$went" =~ ^303\ ($admin/requests/[0-9a-f]{32})$ ]] || fail "making the key got \"$went\""
request="${BASH_REMATCH[1]}"
scripts/firefly-pocket console apply
[ "$(state "${request##*/}")" = applied ] || fail "the key request: $(state "${request##*/}")"
went="$(ask_console -o /dev/null -w '%{http_code} %{redirect_url}' "$request")"
[ "$went" = "303 $admin/bank" ] || fail "a made key should lead back to the bank page, but got \"$went\""
ask_console -f -o "$jar/application.crt" "$admin/bank/certificate" || fail "the console hands out no certificate"
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
# shellcheck source=bank.sh
source "$REPO_ROOT/scripts/bank.sh"
[ "$(openssl x509 -in "$jar/application.crt" -noout -pubkey)" = "$(eb_pem "$ENABLE_BANKING_PRIVATE_KEY" | openssl pkey -pubout)" ] \
  || fail "the console's certificate is not that of the server's key"
grep -rqF -- "$ENABLE_BANKING_PRIVATE_KEY" compose/console "$jar" && fail "the private key is in a file the console reaches"
mapfile -t redirect_urls < <(eb_redirect_urls)
page="$(ask_console "$admin/bank")"
for want in "${redirect_urls[@]}" 'href="/bank/certificate"' 'name="app_id"'; do
  [[ "$page" == *"$want"* ]] || fail "the bank page has no $want"
done
# The services setup talks to, as far as the server can tell. Their keys are
# made up; the server is told where they are in the environment, as only a test
# can tell it.
app_id=3f9c2a71-5d0e-4b8a-9c21-7d4e5f6a8b90
random="$(LC_ALL=C tr -dc 'a-z0-9' < <(LC_ALL=C head -c 1024 /dev/urandom))"
anthropic_key="sk-ant-api03-boot-test-${random:0:32}"
healthchecks_key="${random:32:32}"
mkdir "$jar/outside"
jq -n --arg cert "$jar/application.crt" --arg app_id "$app_id" --arg anthropic "$anthropic_key" \
  --arg healthchecks "$healthchecks_key" --args '{cert: $cert, app_id: $app_id, redirect_urls: $ARGS.positional,
    anthropic_key: $anthropic, healthchecks_key: $healthchecks}' "${redirect_urls[@]}" > "$jar/outside/config.json"
cat > "$jar/outside/outside.py" <<'STUB'
# Stand-ins for the services setup talks to, on one port, as far as the server
# can tell them apart: Enable Banking's GET /application (a token signed with
# the key of the certificate the console handed out last, for this application ID),
# Anthropic's GET /v1/models/<model> (this key), healthchecks.io's
# POST /api/v3/checks/ (this API key) and its pings, and an ntfy topic under
# /ntfy/. Everything sent to it is listed at GET /log, for the test to read.
import base64, json, subprocess, sys, tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer

config = json.load(open(sys.argv[1]))
port_file = sys.argv[2]
log = []


def unb64(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def signed(token):
    """Read the certificate again each time: a new key's is uploaded over it."""
    try:
        header, payload, signature = token.split(".")
        head, claims = json.loads(unb64(header)), json.loads(unb64(payload))
        with tempfile.NamedTemporaryFile(suffix=".pem") as pub, tempfile.NamedTemporaryFile() as sig:
            pub.write(subprocess.run(["openssl", "x509", "-in", config["cert"], "-noout", "-pubkey"],
                                     check=True, capture_output=True).stdout)
            pub.flush()
            sig.write(unb64(signature))
            sig.flush()
            verified = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub.name, "-signature", sig.name],
                                      input=f"{header}.{payload}".encode(), capture_output=True).returncode == 0
        return verified and head.get("alg") == "RS256" and head.get("kid") == config["app_id"] \
            and claims.get("iss") == "enablebanking.com" and claims.get("aud") == "api.enablebanking.com"
    except Exception:
        return False


class Handler(BaseHTTPRequestHandler):
    def answer(self, status, body):
        data = (json.dumps(body) if not isinstance(body, str) else body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        if self.path == "/application":
            if auth.startswith("Bearer ") and signed(auth[7:]):
                return self.answer(200, {"name": "Firefly Pocket CI", "environment": "PRODUCTION",
                                         "redirect_urls": config["redirect_urls"], "services": ["AIS"]})
            return self.answer(401, {"code": 401, "message": "Wrong signature"})
        if self.path.startswith("/v1/models/"):
            if self.headers.get("x-api-key") != config["anthropic_key"]:
                return self.answer(401, {"type": "error", "error": {"type": "authentication_error",
                                                                     "message": "invalid x-api-key"}})
            model = self.path.rsplit("/", 1)[1]
            if not model.startswith("claude-"):
                return self.answer(404, {"type": "error", "error": {"message": f"model: {model}"}})
            return self.answer(200, {"type": "model", "id": model})
        if self.path == "/log":
            return self.answer(200, log)
        return self.answer(404, {"error": "not found"})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode(errors="replace")
        if self.path == "/api/v3/checks/":
            if self.headers.get("X-Api-Key") != config["healthchecks_key"]:
                return self.answer(401, {"error": "wrong api key"})
            check = json.loads(body)
            log.append({"to": "healthchecks", "name": check.get("name"), "schedule": check.get("schedule"),
                        "tz": check.get("tz")})
            slug = check["name"].lower().replace(" ", "-")
            host = self.headers.get("Host")
            return self.answer(201, {"name": check["name"], "ping_url": f"http://{host}/ping/{slug}"})
        if self.path.startswith("/ping/") or self.path.startswith("/ntfy/"):
            log.append({"to": self.path, "title": self.headers.get("Title", ""), "body": body})
            return self.answer(200, {"ok": True})
        return self.answer(404, {"error": "not found"})

    def log_message(self, *args):
        pass


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
STUB
python3 "$jar/outside/outside.py" "$jar/outside/config.json" "$jar/outside/port" &
stub=$!
for _ in $(seq 20); do [ -s "$jar/outside/port" ] && break; sleep 0.5; done
[ -s "$jar/outside/port" ] || fail "the stand-ins did not start"
outside="http://127.0.0.1:$(cat "$jar/outside/port")"
export EB_API="$outside" ANTHROPIC_API="$outside" HEALTHCHECKS_API="$outside"
bank() {
  ask_console "${here[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' --data-urlencode "app_id=$1" "$admin/bank"
}
went="$(bank not-an-id)"
[ "$went" = "400 " ] || fail "a malformed application ID got \"$went\""
went="$(bank 1b4e28ba-2fa1-11d2-883f-0016d3cca427)"
[[ "$went" =~ ^303\ ($admin/requests/[0-9a-f]{32})$ ]] || fail "an application ID got \"$went\""
request="${BASH_REMATCH[1]}"
scripts/firefly-pocket console apply
[ "$(state "${request##*/}")" = refused ] || fail "another application's ID: $(state "${request##*/}"), not refused"
[[ "$(ask_console "$request")" == *"Wrong signature"* ]] || fail "the console does not say why the ID was refused"
scripts/firefly-pocket config has ENABLE_BANKING_APP_ID && fail "an ID Enable Banking refused was kept"
went="$(bank "$app_id")"
[[ "$went" =~ ^303\ ($admin/requests/[0-9a-f]{32})$ ]] || fail "the application's ID got \"$went\""
request="${BASH_REMATCH[1]}"
scripts/firefly-pocket console apply
[ "$(state "${request##*/}")" = applied ] || fail "the application's ID: $(state "${request##*/}"): $(jq -r --arg id "${request##*/}" '.requests[$id].message' compose/console/status/status.json)"
[ "$(scripts/firefly-pocket config get ENABLE_BANKING_APP_ID)" = "$app_id" ] || fail "the application's ID was not kept"
# What compose gave the importer: it is recreated with the ID.
given="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$(compose ps -q importer)" | grep '^ENABLE_BANKING_APP_ID=' || true)"
[ "$given" = "ENABLE_BANKING_APP_ID=$app_id" ] || fail "the importer did not start again with the ID: it has \"$given\""
page="$(ask_console "$request")"
[[ "$page" == *"Firefly Pocket CI"*"Next: Suggestions"* ]] || fail "the console does not say the ID was kept"
echo "the key stays on the server, its certificate is handed out, and only the right ID is kept"

echo "==> the console's suggestions and alerts: each kept once it works"
# post <path> <form fields...>: the console's request, applied. Not in a
# subshell: request is the one it made, posted what became of it, and said what
# the server said.
post() {
  local path="$1" went field data=(--data '')
  shift
  for field; do data+=(--data-urlencode "$field"); done
  went="$(ask_console "${here[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' "${data[@]}" "$admin$path")"
  [[ "$went" =~ ^303\ ($admin/requests/[0-9a-f]{32})$ ]] || fail "$path got \"$went\""
  request="${BASH_REMATCH[1]}"
  scripts/firefly-pocket console apply >/dev/null
  posted="$(state "${request##*/}")"
  said="$(jq -r --arg id "${request##*/}" '.requests[$id].message // ""' compose/console/status/status.json)"
}
heard() { curl -fsS "$outside/log" | jq -r "$1"; }
post /suggestions provider=anthropic "key=sk-ant-api03-not-$anthropic_key" model=
[ "$posted" = refused ] || fail "a key the provider does not take: $posted: $said"
[[ "$said" == *"invalid x-api-key"* ]] || fail "the server does not say why the key was refused: $said"
[[ "$(ask_console "$request")" == *"invalid x-api-key"* ]] || fail "the console does not say why the key was refused"
scripts/firefly-pocket config has ANTHROPIC_API_KEY && fail "a key the provider refused was kept"
post /suggestions provider=anthropic "key=$anthropic_key" model=
[ "$posted" = applied ] || fail "the AI key: $posted: $said"
[ "$(scripts/firefly-pocket config get SUGGESTER_MODEL)" = claude-haiku-5-5 ] || fail "the model is not the default"
[[ "$(ask_console "$admin/suggestions")" == *"…${anthropic_key: -4}"* ]] || fail "the console does not show the key's last four"
topic="$outside/ntfy/firefly-pocket-boot-test"
post /alerts/ntfy "url=http://127.0.0.1:9/ntfy/nobody"
[ "$posted" = refused ] || fail "a topic ntfy does not take: $posted: $said"
post /alerts/ntfy "url=$topic"
[ "$posted" = applied ] || fail "the ntfy topic: $posted: $said"
post /alerts/test
[ "$posted" = applied ] || fail "the test alert: $posted: $said"
[ "$(heard '[.[] | select(.to == "/ntfy/firefly-pocket-boot-test")] | length')" = 2 ] \
  || fail "ntfy should have two test alerts: $(heard '.')"
post /alerts/healthchecks "key=x$healthchecks_key"
[ "$posted" = refused ] || fail "a wrong healthchecks.io key: $posted: $said"
post /alerts/healthchecks "key=$healthchecks_key"
[ "$posted" = applied ] || fail "the checks: $posted: $said"
[ "$(heard '[.[] | select(.to == "healthchecks") | "\(.name) \(.schedule) \(.tz)"] | join(", ")')" \
  = "Firefly Pocket nightly 0 3 * * * Europe/Ljubljana, Firefly Pocket backup 0 2 * * * Europe/Ljubljana" ] \
  || fail "the checks are not the two, in the server's timezone: $(heard '.')"
[ "$(heard '[.[] | select(.to | startswith("/ping/"))] | length')" = 2 ] || fail "the checks were not pinged once each"
for key in HEALTHCHECK_NIGHTLY_URL HEALTHCHECK_BACKUP_URL NTFY_URL; do
  scripts/firefly-pocket config has "$key" || fail "$key was not kept"
done
for secret in "$anthropic_key" "$healthchecks_key" firefly-pocket-boot-test; do
  grep -rqF -- "$secret" compose/console && fail "a key or the topic is in a file the console reaches"
done
grep -rqF -- "$healthchecks_key" compose/config.json compose/secrets compose/.env && fail "the healthchecks.io API key was kept"
echo "the AI key, the topic and the checks are kept once they work, and the console sees only their last four"

echo "==> the console's backups: a repository made with the password it shows once"
repository="$jar/restic"
shown="$(ask_console "$admin/backups" | sed -n 's/.*<p class="password"><code>\([A-Za-z0-9]*\)<\/code>.*/\1/p' | head -n 1)"
[ "${#shown}" -ge 32 ] || fail "the backups page shows no password to keep"
went="$(ask_console "${here[@]}" -o /dev/null -w '%{http_code}' --data-urlencode "repository=$repository" \
  --data-urlencode mode=new --data-urlencode "new_password=$shown" "$admin/backups")"
[ "$went" = 400 ] || fail "the console sent a new repository's password nobody said they kept: $went"
post /backups "repository=$repository" mode=existing password=not-its-password
[ "$posted" = refused ] || fail "an empty place as a repository restic uses: $posted: $said"
[[ "$said" == *"Nothing is there yet"* ]] || fail "the server does not say nothing is there: $said"
post /backups "repository=$repository" mode=new "new_password=$shown" saved=yes
[ "$posted" = applied ] || fail "the new repository: $posted: $said"
RESTIC_REPOSITORY="$repository" RESTIC_PASSWORD="$shown" restic --no-cache cat config >/dev/null \
  || fail "the repository does not open with the password the console showed"
[ "$(scripts/firefly-pocket config get RESTIC_REPOSITORY)" = "$repository" ] || fail "the repository was not kept"
[[ "$(ask_console "$admin/backups")" != *"$shown"* ]] || fail "the console shows the password again once the repository is made"
post /backups "repository=$repository" mode=existing password=not-its-password
[ "$posted" = refused ] || fail "a wrong password: $posted: $said"
post /backups "repository=$repository" mode=existing "password=$shown"
[ "$posted" = applied ] || fail "the repository with its password: $posted: $said"
[[ "$said" == *"0 snapshots"* ]] || fail "the server does not say what is in the repository: $said"
grep -rqF -- "$shown" compose/console && fail "the restic password is in a file the console reaches"
echo "the repository is made with the password the console shows once, and kept once it opens"

echo "==> the console's updates: the deploy agent turned on"
# Stand-ins for sudo and systemctl: the runner's own would start the deploy
# agent here, and it would reset this checkout to master. The units go to
# $jar/systemd, and the timer is on once it is enabled.
mkdir -p "$jar/fake" "$jar/systemd"
cat > "$jar/fake/sudo" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  -n) [ "${2:-}" = true ] && [ -z "${FAKE_NO_SUDO:-}" ] && exit 0; exit 1 ;;
  tee) cat > "$FAKE_SYSTEMD/$(basename "$2")"; exit 0 ;;
  systemctl) shift; exec systemctl "$@" ;;
esac
echo "stand-in sudo: not $*" >&2
exit 1
FAKE
cat > "$jar/fake/systemctl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_SYSTEMD/calls"
case "$*" in
  "is-enabled --quiet fireflyx-deploy.timer") [ -f "$FAKE_SYSTEMD/enabled" ] ;;
  "enable --now fireflyx-deploy.timer") touch "$FAKE_SYSTEMD/enabled" ;;
esac
FAKE
chmod +x "$jar/fake/sudo" "$jar/fake/systemctl"
[[ "$(ask_console "$admin/updates")" == *"Turn on the deploy agent"* ]] || fail "the updates page offers no deploy agent"
PATH="$jar/fake:$PATH" FAKE_SYSTEMD="$jar/systemd" FAKE_NO_SUDO=1 post /updates
[ "$posted" = refused ] || fail "the deploy agent without sudo: $posted: $said"
[[ "$said" == *"no sudo without a password"* ]] || fail "the server does not say it needs sudo: $said"
[ ! -e "$jar/systemd/enabled" ] || fail "the timer was enabled without sudo"
PATH="$jar/fake:$PATH" FAKE_SYSTEMD="$jar/systemd" post /updates
[ "$posted" = applied ] || fail "the deploy agent: $posted: $said"
grep -qx "ExecStart=$REPO_ROOT/scripts/deploy.sh" "$jar/systemd/fireflyx-deploy.service" \
  || fail "the deploy unit does not run this checkout's deploy.sh: $(cat "$jar/systemd/fireflyx-deploy.service")"
grep -qx "User=$(id -un)" "$jar/systemd/fireflyx-deploy.service" || fail "the deploy unit does not run as the agent's user"
grep -qx 'enable --now fireflyx-deploy.timer' "$jar/systemd/calls" || fail "the timer was not enabled"
[ "$(jq -r .updates.agent compose/console/status/status.json)" = true ] || fail "the status does not say the agent is on"
[[ "$(ask_console "$admin/updates")" == *"The deploy agent is on"* ]] || fail "the console does not say the agent is on"
echo "the deploy agent is turned on only where sudo needs no password, for this checkout"

echo "==> the console's Finish: the setup code goes"
went="$(ask_console "${here[@]}" -o /dev/null -w '%{http_code} %{redirect_url}' --data '' "$admin/finish")"
[[ "$went" =~ ^303\ ($admin/requests/[0-9a-f]{32})$ ]] || fail "Finish got \"$went\""
request="${BASH_REMATCH[1]}"
scripts/firefly-pocket console apply
[ "$(state "${request##*/}")" = applied ] || fail "Finish: $(state "${request##*/}")"
scripts/firefly-pocket config has SETUP_CODE && fail "Finish left the setup code"
# The console starts again, without the code.
for _ in $(seq 30); do
  page="$(ask_console "$admin/" 2>/dev/null || true)"
  [[ "$page" == *"Setup is finished"* ]] && break
  sleep 2
done
[[ "$page" == *"Setup is finished"* ]] || fail "the console does not say setup is finished"
headers="$(ask_console "${here[@]}" -o /dev/null -D - --data-urlencode "code=$SETUP_CODE" "$admin/login")"
grep -qi '^set-cookie:' <<<"$headers" && fail "the setup code still signs in"
echo "setup is finished, and the code signs in no more"

# ----------------------------------------------------------- over SSH ---
answers=(
  ''               # Domain: localhost, from setup web
  ''               # Email: ci@example.com, from setup web
  ''               # Name: CI Operator, saved in the console
  ''               # Timezone: Europe/Ljubljana, saved in the console
                   # Firefly III account: the console made it, so no password is asked
  ''               # bank import: the console's ID, checked again with the stand-in
  ''               # AI key: the console's, checked again with the stand-in
  ''               # ntfy: the console's topic
  n                # no test alert
  ''               # healthchecks.io: the console's checks
  ''               # restic repository: the console's, opened again
  n                # deploy agent: off, never on a runner
)
echo "==> scripts/firefly-pocket setup, as a new server runs it next, with throwaway answers"
printf '%s\n' "${answers[@]}" | scripts/firefly-pocket setup | tee "$jar/setup.out"
grep -q 'ok: the repository opens' "$jar/setup.out" || fail "the wizard did not open the console's repository again"
if grep -E '^[A-Z_]+_HOSTNAME=' "$ENV_FILE"; then
  fail "a new server should need only DOMAIN, but compose/.env sets the hostnames above"
fi
[ "$(scripts/firefly-pocket config get LEGAL_OWNER_NAME)" = "CI Operator" ] || fail "Enter did not keep the name"

# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"

echo "==> setup is finished: the console changes nothing"
page="$(ask_console "$admin/")"
[[ "$page" == *"Setup is finished"* ]] || fail "the console does not say setup is finished"
[ "$(scripts/firefly-pocket config get ENABLE_BANKING_APP_ID)" = "$app_id" ] || fail "Enter did not keep the application's ID"
printf '{"action":"server","code":"%s","settings":{"DOMAIN":"localhost","SITE_OWNER":"ci@example.com","LEGAL_OWNER_NAME":"","TZ":"Etc/UTC"}}' \
  "$code" > "$inbox/$(fake_id d).json"
scripts/firefly-pocket console apply
[ "$(state "$(fake_id d)")" = refused ] || fail "the agent applied a request after setup: $(state "$(fake_id d)")"
[ "$(scripts/firefly-pocket config get TZ)" = Europe/Ljubljana ] || fail "the timezone changed after setup"
echo "the agent refused a request with the old code"
tokens=("$IMPORTER_FIREFLY_TOKEN" "$SUGGESTER_FIREFLY_TOKEN" "$NEXT_WARMUP_FIREFLY_TOKEN")
if [ "$(printf '%s\n' "${tokens[@]}" | sort -u | wc -l)" -ne 3 ]; then
  echo "FATAL: the three apps should have a token each" >&2
  exit 1
fi
[ "${tokens[*]}" = "${made[*]}" ] || fail "scripts/firefly-pocket setup made new tokens, where the console's worked"

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

echo "==> after setup, the console signs its owner in with Firefly III"
[ -n "$(jq -r '.signin.client_id // empty' compose/console/status/status.json)" ] \
  || fail "the console has no sign-in client: $(jq -c .signin compose/console/status/status.json)"
[ -n "$(scripts/firefly-pocket config get CONSOLE_CLIENT_ID)" ] || fail "CONSOLE_CLIENT_ID was not kept"
# A browser, as far as Caddy and Firefly III can tell: every *.localhost name is
# this machine, Caddy's own CA is not checked, and redirects are followed by
# hand. The password comes on stdin.
cat > "$jar/browser.py" <<'BROWSER'
import html, http.cookiejar, re, socket, ssl, subprocess, sys, time, urllib.parse, urllib.request

admin, firefly, email = sys.argv[1:4]
rotate = sys.argv[4:5] == ["rotate"]
password = sys.stdin.readline().rstrip("\n")
resolve = socket.getaddrinfo
socket.getaddrinfo = lambda host, *a, **k: resolve("127.0.0.1" if host.endswith(".localhost") else host, *a, **k)
context = ssl.create_default_context()
context.check_hostname = False
context.verify_mode = ssl.CERT_NONE


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context),
                                     urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()), NoRedirect)


def go(url, form=None):
    """The page a browser ends up on, and its URL, following every redirect."""
    for _ in range(10):
        data = urllib.parse.urlencode(form).encode() if form is not None else None
        try:
            r = opener.open(urllib.request.Request(url, data=data))
            status, headers, body = r.status, r.headers, r.read().decode()
        except urllib.error.HTTPError as e:
            status, headers, body = e.code, e.headers, e.read().decode()
        if status in (301, 302, 303) and headers.get("Location"):
            url, form = urllib.parse.urljoin(url, headers["Location"]), None
            print("->", url.split("?")[0])
            continue
        return status, body, url
    sys.exit("too many redirects")


def through_firefly(start):
    """From a URL that leads to Firefly III's login: signed in there, and on wherever it sends the browser after."""
    status, page, url = go(start)
    if not url.startswith(f"https://{firefly}/login"):
        sys.exit(f"the sign-in did not reach Firefly III's login page: {status} {url}")
    token = re.search(r'name="_token" value="([^"]+)"', page).group(1)
    status, page, url = go(f"https://{firefly}/login", {"_token": token, "email": email, "password": password})
    if url.startswith(f"https://{firefly}/oauth/authorize"):
        # Firefly III asks once per client whether to let it in: the first form approves.
        approve = page.split("</form>")[0]
        form = {re.search(r'name="([^"]+)"', i).group(1): html.unescape(re.search(r'value="([^"]*)"', i).group(1))
                for i in re.findall(r"<input[^>]*>", approve) if 'name="' in i and 'value="' in i}
        status, page, url = go(f"https://{firefly}/oauth/authorize", form)
    return status, page, url


if sys.argv[4:5] == ["pocket"]:
    # pocket <Pocket's host>: Firefly Pocket's "Sign in with Firefly III", as its page does it in the browser
    # (lib/signin.js): the offer, Firefly III's login with a PKCE challenge, back to /oauth/callback, and the code
    # swapped for a token by Pocket's server. Then the token at Pocket's /api/user.
    import base64, hashlib, json, secrets
    app = sys.argv[5]
    with opener.open(f"https://{app}/api/signin") as r:
        offer = json.load(r)
    if not offer.get("available") or offer.get("redirect_uri") != f"https://{app}/oauth/callback" \
            or offer.get("authorize_url") != f"https://{firefly}/oauth/authorize":
        sys.exit(f"Firefly Pocket does not offer the sign-in as it should: {offer}")
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(24)
    query = urllib.parse.urlencode({"client_id": offer["client_id"], "redirect_uri": offer["redirect_uri"],
                                    "response_type": "code", "scope": "", "state": state,
                                    "code_challenge": challenge, "code_challenge_method": "S256"})
    status, page, url = through_firefly(f"{offer['authorize_url']}?{query}")
    back = urllib.parse.urlsplit(url)
    sent = dict(urllib.parse.parse_qsl(back.query))
    if f"{back.scheme}://{back.netloc}{back.path}" != offer["redirect_uri"] or sent.get("state") != state or not sent.get("code"):
        sys.exit(f"Firefly III did not send the browser back to Pocket with a code: {status} {url.split('?')[0]}")
    print("BACK AT", offer["redirect_uri"], status)

    def swap(code, code_verifier):
        request = urllib.request.Request(f"https://{app}/api/signin/token", method="POST",
                                         data=json.dumps({"code": code, "code_verifier": code_verifier}).encode(),
                                         headers={"Content-Type": "application/json", "Accept": "application/json"})
        try:
            with opener.open(request) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    # The code is worth nothing without the browser's verifier, and is spent once used.
    print("WRONG VERIFIER", swap(sent["code"], secrets.token_urlsafe(48))[0])
    status, answer = swap(sent["code"], verifier)
    print("SWAPPED", status, "token" in answer)
    print("AGAIN", swap(sent["code"], verifier)[0])
    if status != 200 or not answer.get("token"):
        sys.exit(f"Pocket's server did not swap the code for a token: {status} {answer}")
    with opener.open(urllib.request.Request(f"https://{app}/api/user", headers={
            "Authorization": f"Bearer {answer['token']}", "Accept": "application/json"})) as r:
        user = json.load(r)
    print("POCKET SIGNED IN AS " + user.get("data", {}).get("attributes", {}).get("email", "nobody"))
    sys.exit(0)

status, page, url = through_firefly(f"https://{admin}/signin")
print(status, url)
print("SIGNED IN AS " + email if f"Signed in with Firefly III as {email}" in page else page[-1500:])
if not rotate:
    sys.exit(0)


# rotate <application ID> <certificate file>: as the owner would, still signed
# in, make a new bank key, upload its certificate (to the file Enable Banking's
# stand-in reads), give the application ID again, then sign out. The server
# applies each request as its systemd unit would.
def post(path, form):
    """A form sent from the console's own page: the status, and where it sends the browser."""
    request = urllib.request.Request(f"https://{admin}{path}", data=urllib.parse.urlencode(form).encode(),
                                     headers={"Origin": f"https://{admin}"})
    try:
        r = opener.open(request)
        status, headers = r.status, r.headers
        r.read()
    except urllib.error.HTTPError as e:
        status, headers = e.code, e.headers
        e.read()
    return status, urllib.parse.urljoin(f"https://{admin}{path}", headers.get("Location") or "")


def handed_over(path, form, label):
    status, url = post(path, form)
    found = re.fullmatch(rf"https://{re.escape(admin)}/requests/([0-9a-f]{{32}})", url)
    if status != 303 or not found:
        sys.exit(f"{path} after setup got {status} {url}, not a request")
    print(label, found.group(1))
    subprocess.run(["scripts/firefly-pocket", "console", "apply"], check=True, stdout=sys.stderr)
    return go(url)


app_id, certificate = sys.argv[5:7]
status, page, url = handed_over("/bank/key", {}, "KEY")
if url != f"https://{admin}/bank":
    sys.exit(f"the new key should lead back to the bank page, but got {status} {url}")
with opener.open(f"https://{admin}/bank/certificate") as r, open(certificate, "wb") as f:
    f.write(r.read())
status, page, url = handed_over("/bank", {"app_id": app_id}, "BANK")
if "Firefly Pocket CI" not in page:
    sys.exit(f"the console does not say the ID was kept: {status} {url} {page[-800:]}")
# The ID just kept starts the importer again: Caddy cannot reach it (502)
# until it listens.
for _ in range(60):
    status, page, url = go(f"https://{admin}/importer/")
    if status not in (502, 503, 504):
        break
    time.sleep(2)
print("IMPORTER", status, url)
if status != 200 or not url.startswith(f"https://{admin}/importer/") or f'href="https://{admin}/importer/' not in page:
    sys.exit(f"the importer's pages are not under https://{admin}/importer/ for the signed-in owner: {status} {url} {page[:600]}")


def peek(path):
    """Where a GET sends the browser, without following it."""
    try:
        r = opener.open(f"https://{admin}{path}")
        r.read()
        return r.status, ""
    except urllib.error.HTTPError as e:
        e.read()
        return e.code, e.headers.get("Location") or ""


status, url = post("/logout", {})
print("SIGNED OUT", status, url)
print("IMPORTER AFTER SIGN OUT", *peek("/importer/"))
subprocess.run(["scripts/firefly-pocket", "console", "apply"], check=True, stdout=sys.stderr)
status, url = post("/bank/key", {})
print("AFTER SIGN OUT", status, url)
BROWSER
cp "$jar/application.crt" "$jar/application.old.crt"
said="$(python3 "$jar/browser.py" "$ADMIN_HOSTNAME" "$FIREFLY_HOSTNAME" ci@example.com \
  rotate "$app_id" "$jar/application.crt" <<<"$password")" || fail "the sign-in stopped: $said"
printf '%s\n' "$said"
grep -qx 'SIGNED IN AS ci@example.com' <<<"$said" || fail "the console did not sign its owner in"
grep -q '/oauth/callback' <<<"$said" || fail "the sign-in did not come back through the console's callback"
echo "the console signs its owner in with Firefly III, with no secret of its own"

echo "==> signed in, the owner makes a new bank key from the browser, then signs out"
message() { jq -r --arg id "$1" '.requests[$id].message' compose/console/status/status.json; }
client="$(scripts/firefly-pocket config get CONSOLE_CLIENT_ID)"
# The console's tokens Firefly III still takes.
console_tokens_live() {
  compose exec -T -e PGPASSWORD="$POSTGRES_SUPER_PASSWORD" db psql -U postgres -d firefly -v ON_ERROR_STOP=1 -tAc \
    "SELECT count(*) FROM oauth_access_tokens WHERE client_id::text = '$client' AND NOT revoked" | tr -d '[:space:]'
}
for label in KEY BANK; do
  id="$(sed -n "s/^$label //p" <<<"$said")"
  [ "$(state "$id")" = applied ] || fail "the $label request after setup: $(state "$id"): $(message "$id")"
done
cmp -s "$jar/application.old.crt" "$jar/application.crt" && fail "the bank page hands out the old certificate"
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
[ "$(openssl x509 -in "$jar/application.crt" -noout -pubkey)" = "$(eb_pem "$ENABLE_BANKING_PRIVATE_KEY" | openssl pkey -pubout)" ] \
  || fail "the new certificate is not that of the server's new key"
[ "$(scripts/firefly-pocket config get ENABLE_BANKING_APP_ID)" = "$app_id" ] || fail "the application's ID was not kept with the new key"
given="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$(compose ps -q importer)" | grep '^ENABLE_BANKING_APP_ID=' || true)"
[ "$given" = "ENABLE_BANKING_APP_ID=$app_id" ] || fail "the importer did not start again with the ID: it has \"$given\""
grep -q '^SIGNED OUT 303 ' <<<"$said" || fail "Sign out did not send the browser on"
signout="$(jq -r '[.requests | to_entries[] | select(.value.action == "signout") | .value.state] | join(" ")' compose/console/status/status.json)"
[ "$signout" = applied ] || fail "the sign-out request: \"$signout\", not applied"
[ "$(console_tokens_live)" = 0 ] || fail "Firefly III still takes $(console_tokens_live) of the console's tokens after Sign out"
grep -q "^AFTER SIGN OUT .*/requests/" <<<"$said" && fail "the console took a request after Sign out"
grep -qx 'IMPORTER 200 https://'"$ADMIN_HOSTNAME"'/importer/.*' <<<"$said" || fail "the owner did not reach the importer's pages"
grep -qx 'IMPORTER AFTER SIGN OUT 303 /' <<<"$said" || fail "the importer's pages let a signed-out browser in: $(grep '^IMPORTER AFTER' <<<"$said")"
echo "a new key and its certificate, the ID kept with it, and Sign out ends the token"

echo "==> after setup, a request needs the owner's sign-in, from the console"
key="$ENABLE_BANKING_PRIVATE_KEY"
printf '{"action":"bank_key"}' > "$inbox/$(fake_id 4).json"
printf '{"action":"bank_key","code":"%s"}' "$code" > "$inbox/$(fake_id 5).json"
printf '{"action":"bank_key","token":"%s"}' "$IMPORTER_FIREFLY_TOKEN" > "$inbox/$(fake_id 6).json"
printf '{"action":"bank_key","token":"not-a-token"}' > "$inbox/$(fake_id 7).json"
scripts/firefly-pocket console apply
for forged in 4 5 6 7; do
  [ "$(state "$(fake_id $forged)")" = refused ] || fail "the request $(fake_id $forged): $(state "$(fake_id $forged)"), not refused"
done
[[ "$(message "$(fake_id 6)")" == *"another app's token"* ]] || fail "the importer's token was refused for another reason: $(message "$(fake_id 6)")"
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
[ "$ENABLE_BANKING_PRIVATE_KEY" = "$key" ] || fail "a refused request changed the bank key"
echo "no token, the old setup code, another app's token and a malformed one are refused"

echo "==> the console's sign-ins end after eight hours"
said="$(python3 "$jar/browser.py" "$ADMIN_HOSTNAME" "$FIREFLY_HOSTNAME" ci@example.com <<<"$password")" \
  || fail "the second sign-in stopped: $said"
grep -qx 'SIGNED IN AS ci@example.com' <<<"$said" || fail "the console did not sign its owner in again: $said"
[ "$(console_tokens_live)" -ge 1 ] || fail "the sign-in left no token Firefly III takes"
compose exec -T -e PGPASSWORD="$POSTGRES_SUPER_PASSWORD" db psql -U postgres -d firefly -v ON_ERROR_STOP=1 -qc \
  "UPDATE oauth_access_tokens SET created_at = created_at - interval '9 hours' WHERE client_id::text = '$client'"
expired="$(scripts/firefly-pocket console expire)"
printf '%s\n' "$expired"
grep -Eq ' [1-9][0-9]* revoked$' <<<"$expired" || fail "console expire revoked nothing: $expired"
[ "$(console_tokens_live)" = 0 ] || fail "Firefly III still takes a console token nine hours old"
echo "console expire revokes the console's tokens older than eight hours"

echo "==> Firefly Pocket signs a new device in with Firefly III, with no token pasted"
pocket_client="$(scripts/firefly-pocket config get POCKET_CLIENT_ID)"
[ -n "$pocket_client" ] && [ "$pocket_client" != "$client" ] || fail "POCKET_CLIENT_ID is not a client of Pocket's own: \"$pocket_client\""
given="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$(compose ps -q next)" | grep '^FIREFLY_CLIENT_ID=' || true)"
[ "$given" = "FIREFLY_CLIENT_ID=$pocket_client" ] || fail "Firefly Pocket runs without its client: \"$given\""
said="$(python3 "$jar/browser.py" "$ADMIN_HOSTNAME" "$FIREFLY_HOSTNAME" ci@example.com pocket "$NEXT_HOSTNAME" <<<"$password")" \
  || fail "Firefly Pocket's sign-in stopped: $said"
printf '%s\n' "$said"
grep -qx "BACK AT https://$NEXT_HOSTNAME/oauth/callback 200" <<<"$said" || fail "Firefly III did not send the browser back to Pocket's page"
grep -qx 'WRONG VERIFIER 400' <<<"$said" || fail "Pocket's server swapped a code with another verifier: $(grep '^WRONG' <<<"$said")"
grep -qx 'SWAPPED 200 True' <<<"$said" || fail "Pocket's server did not swap the code for a token"
grep -qx 'AGAIN 400' <<<"$said" || fail "the same code was swapped twice: $(grep '^AGAIN' <<<"$said")"
grep -qx 'POCKET SIGNED IN AS ci@example.com' <<<"$said" || fail "the token Pocket got is not the owner's"
echo "a code with its verifier, once, is a token that works in Pocket; with another verifier or again, nothing"

echo "==> the apps' tokens: made again near their end, each app started again with its new one"
# What the nightly run does first (scripts/tokens.sh). A token made today has a
# year left, so nothing is due at 30 days; at 400, every token is.
scripts/firefly-pocket tokens | tee "$jar/tokens.out"
for key in IMPORTER_FIREFLY_TOKEN SUGGESTER_FIREFLY_TOKEN NEXT_WARMUP_FIREFLY_TOKEN; do
  grep -Eq "^$key \(\"[^\"]+\"\): 36[3-6] days left$" "$jar/tokens.out" \
    || fail "$key should have a year left: $(grep "^$key" "$jar/tokens.out")"
done
scripts/firefly-pocket tokens rotate | tee "$jar/rotate.out"
grep -q 'a new one' "$jar/rotate.out" && fail "a token with a year left was made again"
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
[ "$IMPORTER_FIREFLY_TOKEN $SUGGESTER_FIREFLY_TOKEN $NEXT_WARMUP_FIREFLY_TOKEN" = "${tokens[*]}" ] \
  || fail "tokens rotate changed a token that was not due"
scripts/firefly-pocket tokens rotate --days 400 | tee "$jar/rotate.out"
[ "$(grep -c 'a new token' "$jar/rotate.out")" -eq 3 ] || fail "tokens rotate --days 400 did not make all three again"
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
rotated=("$IMPORTER_FIREFLY_TOKEN" "$SUGGESTER_FIREFLY_TOKEN" "$NEXT_WARMUP_FIREFLY_TOKEN")
for i in 0 1 2; do
  [ "${rotated[$i]}" != "${tokens[$i]}" ] || fail "token $((i + 1)) of 3 was not made again"
  grep -qF -- "${rotated[$i]}" "$jar/rotate.out" && fail "tokens rotate printed a token"
  token_check "${rotated[$i]}"
  went="$(printf 'header = "Authorization: Bearer %s"\n' "${tokens[$i]}" \
    | docker run --rm -i --network "$DOCKER_NETWORK" "$CURL_IMAGE" -sS --max-time 30 --config - \
        -H 'Accept: application/vnd.api+json' -o /dev/null -w '%{http_code}' http://app:8080/api/v1/about/user)"
  [[ "$went" =~ ^40[13]$ ]] || fail "Firefly III still takes the old token $((i + 1)) of 3 (HTTP $went)"
done
given="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$(compose ps -q importer)" | grep '^FIREFLY_III_ACCESS_TOKEN=' || true)"
[ "$given" = "FIREFLY_III_ACCESS_TOKEN=$IMPORTER_FIREFLY_TOKEN" ] || fail "the importer did not start again with its new token"
given="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$(compose ps -q next)" | grep '^WARMUP_FIREFLY_TOKEN=' || true)"
[ "$given" = "WARMUP_FIREFLY_TOKEN=$NEXT_WARMUP_FIREFLY_TOKEN" ] || fail "Firefly Pocket did not start again with its new token"
internal_http http://importer:8080/health 30 >/dev/null || fail "the importer does not answer after the rotation"
echo "a token near its end is made again, the old one revoked, and its app started again with the new one"

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

# The importer's own pages are on the console's host, behind its sign-in
# (Hostnames and routing step 7): with no session, the browser goes to the
# console, and the fork's API for Firefly Pocket is not there at all. A
# callback of the importer's own flow (a UUID state) arriving on Firefly
# Pocket's host goes on to those pages, with its query.
echo "==> the importer's pages on the console's host, behind its sign-in"
went_to() {
  docker run --rm --network "$DOCKER_NETWORK" "$CURL_IMAGE" -sS -k --max-time 30 \
    --connect-to ::caddy:443 -o /dev/null -w '%{http_code} %{redirect_url}' "$1"
}
went="$(went_to "https://$ADMIN_HOSTNAME/importer/")"
[ "$went" = "303 https://$ADMIN_HOSTNAME/" ] || fail "the importer's pages answered \"$went\" with no sign-in, not the console"
went="$(went_to "https://$ADMIN_HOSTNAME/importer")"
[ "$went" = "308 https://$ADMIN_HOSTNAME/importer/" ] || fail "/importer answered \"$went\""
for path in /importer/api/fireflyx/connections /importer/fireflyx/eb-callback; do
  went="$(went_to "https://$ADMIN_HOSTNAME$path")"
  [ "$went" = "404 " ] || fail "the fork's API answered \"$went\" at $path on the console's host"
done
uuid_state=0b6e2c1a-4f3d-4c2b-9a8e-7d6c5b4a3f21
went="$(went_to "https://$NEXT_HOSTNAME/eb-callback?state=$uuid_state&code=boot-test")"
[ "$went" = "302 https://$ADMIN_HOSTNAME/importer/eb-callback?state=$uuid_state&code=boot-test" ] \
  || fail "the importer's own callback on Firefly Pocket's host answered \"$went\""
echo "no sign-in, no importer; its API is not there; its own callbacks go on to it"

echo "==> booted and checked"
