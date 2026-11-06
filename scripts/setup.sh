#!/usr/bin/env bash
#
# Firefly Pocket's setup wizard (Setup UI step 2). On the server, over SSH:
#
#     scripts/firefly-pocket setup            every step, in order
#     scripts/firefly-pocket setup <step>     one step again, then start
#
# Each step asks only for what you have to give, checks it, and keeps it in the
# settings store (scripts/config.sh); everything else is generated, the Firefly
# III tokens included. Run it again to change an answer: Enter keeps what is
# there. compose/.env is written from the store, so nobody opens it.
#
#   domain       the domain, and that each of its four names resolves to this server
#   you          your email, your name for the legal pages and the timezone; then
#                every secret is generated (gen-secrets.sh)
#   account      your Firefly III account and a token for each app, made inside
#                Firefly III (scripts/firefly-bootstrap.php); /register is closed after
#   start        every service started (by the deploy agent, once it runs), and each
#                name's certificate checked
#   bank         Enable Banking: a key and certificate made here for the application
#                you register, then its ID, checked with a signed request
#   suggestions  an Anthropic or Gemini key, checked by asking for the model
#   alerts       an ntfy topic made here and tested; healthchecks.io checks made with its API key
#   backups      a restic repository, opened or created; its password shown to keep
#   updates      the deploy agent (scripts/install-deploy-agent.sh), which keeps this
#                server on master and installs the nightly jobs
#
# The full run starts the stack once the account exists, so nothing is public
# before then, and again at the end with every answer. Answers are read from stdin
# when it is not a terminal, one line each, which is how the boot test runs it
# (scripts/boot-test.sh).

set -euo pipefail
shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/compose"
CONFIG="$COMPOSE_DIR/config.json"
FP="$REPO_ROOT/scripts/firefly-pocket"
EB_CERT="$COMPOSE_DIR/secrets/eb/application.crt"
STEPS="domain you account start bank suggestions alerts backups updates"

# The apps' Firefly III tokens: the setting, and the token's name in Firefly III
# (Options -> Profile -> OAuth), where each can be revoked alone.
TOKENS=(
  "IMPORTER_FIREFLY_TOKEN:Firefly Pocket importer"
  "SUGGESTER_FIREFLY_TOKEN:Firefly Pocket suggester"
  "NEXT_WARMUP_FIREFLY_TOKEN:Firefly Pocket warm-up"
)

# Answers come from the terminal, or else from stdin, which then moves to fd 3:
# no command the wizard runs can read an answer meant for a later question.
TTY=""
if [ -t 0 ]; then
  TTY=1
else
  exec 3<&0 </dev/null
fi
SKIPPED=()
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

die() { echo "FATAL: $*" >&2; exit 1; }
heading() { printf '\n== %s\n' "$*"; }
say() { printf '   %s\n' "$@"; }
ok() { printf '   ok: %s\n' "$*"; }
problem() { printf '   !! %s\n' "$*"; }
compose() { docker compose --project-directory "$COMPOSE_DIR" "$@"; }

# ------------------------------------------------------------- asking ---
# ask <prompt> [default]: one line into ANSWER; Enter gives the default.
ask() {
  local prompt="   $1${2:+ [$2]}: "
  if [ -n "$TTY" ]; then
    IFS= read -r -e -p "$prompt" ANSWER || die "no answer to \"$1\""
  else
    printf '%s' "$prompt"
    IFS= read -r -u 3 ANSWER || die "no answer to \"$1\": the input ended"
    printf '%s\n' "$ANSWER"
  fi
  ANSWER="${ANSWER:-${2:-}}"
}

# ask_secret <prompt>: the same, not shown and with no default.
ask_secret() {
  if [ -n "$TTY" ]; then
    IFS= read -r -s -p "   $1: " ANSWER || die "no answer to \"$1\""
  else
    printf '   %s: ' "$1"
    IFS= read -r -u 3 ANSWER || die "no answer to \"$1\": the input ended"
  fi
  echo
}

# confirm <question> <y|n>: yes or no, the second argument on Enter.
confirm() {
  local hint="[Y/n]"
  [ "$2" = y ] || hint="[y/N]"
  while :; do
    ask "$1 $hint"
    case "${ANSWER:-$2}" in
      [Yy] | [Yy][Ee][Ss]) return 0 ;;
      [Nn] | [Nn][Oo]) return 1 ;;
    esac
    say "y or n"
  done
}

# -------------------------------------------------------------- store ---
# get <KEY>: what a plain setting is, its default included; a secret only says
# whether it is set. Nothing before the store exists.
get() { [ ! -f "$CONFIG" ] || "$FP" config get "$1"; }
# stored <KEY>: a plain setting only as it was set, without the default.
stored() { [ ! -f "$CONFIG" ] || jq -r --arg k "$1" '.[$k] // empty' "$CONFIG"; }
has() { "$FP" config has "$1"; }

# put <KEY> <value>: into the store, through config set's check, the value on
# stdin. A value the check refuses says why and returns 1; nothing changes then.
put() {
  local out
  out="$("$FP" config set --no-render "$1" - <<<"$2" 2>&1)" && return 0
  problem "${out#FATAL: }"
  return 1
}

drop() { "$FP" config unset "$1" >/dev/null; }

# ask_setting <KEY> <prompt> [default]: asks until the answer passes KEY's check,
# then keeps it. An empty answer with no default keeps nothing and returns 1.
ask_setting() {
  while :; do
    ask "$2" "${3:-}"
    [ -n "$ANSWER" ] || return 1
    put "$1" "$ANSWER" && return 0
  done
}

# reload: write compose/.env from the store, then read it with lib.sh's helpers.
# Not before the domain step: lib.sh stops while the hostnames are unknown.
reload() {
  "$FP" config render >/dev/null
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"
}

# The four names, as compose and lib.sh derive them: <name>.<domain> unless one
# is set on its own.
names() {
  local domain="$1" pair value
  for pair in FIREFLY_HOSTNAME:firefly NEXT_HOSTNAME:app IMPORT_HOSTNAME:import LEGAL_HOSTNAME:legal; do
    value="$(stored "${pair%%:*}")"
    printf '%s\n' "${value:-${domain:+${pair#*:}.$domain}}"
  done
}

is_localhost() { [[ "$1" == localhost || "$1" == *.localhost ]]; }

# Random lower-case letters and digits, $1 of them, in bounded reads (see
# gen-secrets.sh's randstr for why).
randstr() {
  local out=""
  while [ "${#out}" -lt "$1" ]; do
    out="$out$(LC_ALL=C head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-z0-9')"
  done
  printf '%s' "${out:0:$1}"
}

# Secrets go to curl as a config file on stdin, never on its command line.
# curl_with <header-with-secret> <curl args...>: the response body in $WORK/body,
# the HTTP status on stdout ("000" when there was no answer).
curl_with() {
  local header="$1" code
  shift
  : > "$WORK/body"
  # With no answer at all curl writes 000 itself, and fails.
  code="$(printf 'header = "%s"\n' "$header" \
    | curl -sS --max-time 30 --config - -o "$WORK/body" -w '%{http_code}' "$@" 2>/dev/null || true)"
  printf '%s' "${code:-000}"
}

# --------------------------------------------------------------- domain ---
# my_address 4|6: this server's address on its default route: the public one,
# unless the server sits behind NAT. Nothing when it has none.
my_address() {
  local target=1.1.1.1
  [ "$1" = 4 ] || target=2606:4700:4700::1111
  command -v ip >/dev/null 2>&1 || return 0
  # Without a route (a server with no IPv6) ip fails: no address, not an error.
  { ip "-$1" route get "$target" 2>/dev/null | sed -n 's/.* src \([0-9a-fA-F.:]*\).*/\1/p' | head -n 1; } || true
}

private_v4() { [[ "$1" =~ ^(10\.|127\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; }

# Each name resolves, and only to this server: Let's Encrypt tries every address
# a name has, IPv6 first.
check_dns() {
  local domain v4 v6 host a aaaa addr bad nat=""
  domain="$(get DOMAIN)"
  if is_localhost "$domain"; then
    ok "every *.localhost name is this machine; Caddy gives each a certificate of its own"
    return 0
  fi
  v4="$(my_address 4)"
  v6="$(my_address 6)"
  if [ -z "$v4" ]; then
    nat=1
    say "This server's own address is unknown here (no ip command), so the names can only be checked" \
        "to resolve. The certificates, in the start step, check the rest."
  elif private_v4 "$v4"; then
    nat=1
    say "This server's own address is $v4, not a public one: it sits behind NAT, so the names can only" \
        "be checked to resolve. The certificates, in the start step, check the rest."
  fi
  while :; do
    bad=""
    while IFS= read -r host; do
      a="$(getent ahostsv4 "$host" 2>/dev/null | awk '{ print $1 }' | sort -u || true)"
      aaaa="$(getent ahostsv6 "$host" 2>/dev/null | awk '$1 !~ /^::ffff:/ { print $1 }' | sort -u || true)"
      if [ -z "$a$aaaa" ]; then
        problem "$host does not resolve yet"
        bad=1
        continue
      fi
      for addr in $a; do
        if [ -z "$nat" ] && [ "$addr" != "$v4" ]; then
          problem "$host points to $addr, but this server is $v4"
          bad=1
        fi
      done
      for addr in $aaaa; do
        if [ -z "$v6" ]; then
          problem "$host has the IPv6 address $addr, but this server has none: remove that AAAA record"
          bad=1
        elif [ "$addr" != "$v6" ]; then
          problem "$host points to $addr, but this server's IPv6 address is $v6"
          bad=1
        fi
      done
      [ -n "$bad" ] || ok "$host points here"
    done < <(names "$domain")
    [ -n "$bad" ] || return 0
    say "A new record can take some minutes to show here. Let's Encrypt gives no certificate to a" \
        "name that does not point to this server."
    ask "Enter to look again, or skip to go on regardless"
    if [ "$ANSWER" = skip ]; then
      say "Skipped. The start step checks each certificate."
      return 0
    fi
  done
}

step_domain() {
  heading "Domain"
  local v4 v6 current all_set=1 key
  v4="$(my_address 4)"
  v6="$(my_address 6)"
  [ -n "$v4" ] || v4="<this server's IPv4 address>"
  say "Firefly Pocket answers on four names under a domain of yours: firefly.<domain> is Firefly III," \
      "app.<domain> Firefly Pocket, import.<domain> the bank importer, and legal.<domain> the privacy" \
      "policy and terms. A subdomain works too, such as money.example.com. Point one wildcard record" \
      "at this server first:" \
      "    *.<domain>   A      $v4"
  [ -z "$v6" ] || say "    *.<domain>   AAAA   $v6   (optional)"
  for key in FIREFLY_HOSTNAME NEXT_HOSTNAME IMPORT_HOSTNAME LEGAL_HOSTNAME; do
    [ -n "$(stored "$key")" ] || all_set=""
  done
  current="$(get DOMAIN)"
  while :; do
    ask "Domain" "$current"
    ANSWER="${ANSWER,,}"
    ANSWER="${ANSWER%.}"
    if [ -z "$ANSWER" ]; then
      if [ -n "$all_set" ]; then
        ok "no domain: each of the four names is set on its own ($(names "" | paste -sd' ' -))"
        break
      fi
      problem "a domain is needed"
      continue
    fi
    put DOMAIN "$ANSWER" && break
  done
  check_dns
}

# ------------------------------------------------------------------ you ---
host_timezone() {
  local tz=""
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [ -n "$tz" ] || tz="$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p' || true)"
  printf '%s' "${tz:-Etc/UTC}"
}

# gen-secrets.sh fills every generated value that is empty, and nothing else.
generate() {
  local out
  out="$(FROM_SETUP=1 "$REPO_ROOT/scripts/gen-secrets.sh")"
  grep -q 'Nothing to do' <<<"$out" && return 0
  ok "generated $(sed -n '/Filled:/,/^$/p' <<<"$out" | grep -c '^ *[A-Z]') secrets that nobody needs to see"
  if grep -q 'SAVE THIS NOW' <<<"$out"; then
    printf '%s\n' "$out" | sed -n '/====/,/====/p'
    say "That is the bank importer's password, for its own web page (rarely needed: Firefly Pocket links banks)."
    ask "Saved it? Enter to go on"
  fi
}

step_you() {
  heading "You"
  local old acme vapid
  old="$(get SITE_OWNER)"
  say "One email address of yours: your Firefly III account's, Let's Encrypt's for certificate" \
      "notices, the push services' contact, and the legal pages'."
  until ask_setting SITE_OWNER "Email" "$old"; do problem "an email address is needed"; done
  # The others follow it, unless one was set to something else on purpose.
  acme="$(get ACME_EMAIL)"
  if [ -z "$acme" ] || [ "$acme" = "$old" ]; then put ACME_EMAIL "$ANSWER"; fi
  vapid="$(get VAPID_SUBJECT)"
  if [ -z "$vapid" ] || [ "$vapid" = "mailto:$old" ]; then put VAPID_SUBJECT "mailto:$ANSWER"; fi

  say "" "Your name, as the operator the privacy policy and terms name. Enable Banking's reviewers" \
      "read them. Enter for none (\"the operator of this server\")."
  ask_setting LEGAL_OWNER_NAME "Name" "$(get LEGAL_OWNER_NAME)" || true

  say "" "The timezone the nightly jobs run in (the backup at 02:00, the import at 03:00)."
  local tz
  tz="$(stored TZ)"
  until ask_setting TZ "Timezone" "${tz:-$(host_timezone)}"; do :; done

  generate
  reload
  ok "the settings are in compose/config.json and compose/secrets/env/; compose/.env is written from them"
}

# -------------------------------------------------------------- account ---
# bootstrap: scripts/firefly-bootstrap.php inside the app container, its JSON
# input on stdin. Its answer, the JSON after the marker, on stdout.
bootstrap() {
  local code out answer
  code="$(sed '1{/^<?php/d;}' "$REPO_ROOT/scripts/firefly-bootstrap.php")"
  out="$(compose exec -T app php -r "$code" 2>&1)" || true
  answer="$(sed -n 's/^FIREFLY_POCKET_BOOTSTRAP //p' <<<"$out" | tail -n 1)"
  if [ -z "$answer" ]; then
    printf '%s\n' "$out" | tail -n 15 >&2
    die "scripts/firefly-bootstrap.php gave no answer (its output is above)"
  fi
  if jq -e 'has("error")' <<<"$answer" >/dev/null; then
    die "scripts/firefly-bootstrap.php: $(jq -r .error <<<"$answer")"
  fi
  printf '%s' "$answer"
}

# A token is good when Firefly III's API accepts it.
token_works() {
  [ -n "$1" ] || return 1
  printf 'header = "Authorization: Bearer %s"\n' "$1" \
    | docker run --rm -i --network "$DOCKER_NETWORK" "$CURL_IMAGE" -fsS --max-time 30 --config - \
        -H 'Accept: application/vnd.api+json' -o /dev/null http://app:8080/api/v1/about/user 2>/dev/null
}

# registration open|closed: what Firefly III's /register shows. It answers 200
# either way, so the page is read: open, it has the form with its confirmation field.
registration() {
  local page
  page="$(internal_http http://app:8080/register 60)" || return 1
  if grep -q 'name="password_confirmation"' <<<"$page"; then [ "$1" = open ]; else [ "$1" = closed ]; fi
}

wait_for() {
  local url="$1" what="$2" _
  for _ in $(seq 60); do
    internal_http "$url" 10 >/dev/null 2>&1 && return 0
    sleep 5
  done
  die "$what did not answer within five minutes: docker compose --project-directory compose logs $3"
}

step_account() {
  heading "Your Firefly III account"
  generate
  reload
  say "Postgres and Firefly III first. Caddy, which makes them public, starts only once the account" \
      "exists, so no one else can claim it. The first start sets up the database: a minute or two."
  compose up -d --no-build --quiet-pull db app
  wait_for http://app:8080/health "Firefly III" app

  local info users pw="" entry key name mint=() request answer token
  info="$(bootstrap <<<'{}')"
  users="$(jq -r .users <<<"$info")"
  if [ "$users" = 0 ]; then
    registration open || die "Firefly III's /register shows no registration form, so checking that it closed would prove nothing. This Firefly III needs a newer firefly-pocket-stack."
    say "Its email is $SITE_OWNER. Choose its password: at least 16 characters, Firefly III's minimum." \
        "You sign in to https://$FIREFLY_HOSTNAME with it."
    while :; do
      ask_secret "Password"
      pw="$ANSWER"
      if [ "${#pw}" -lt 16 ]; then problem "at least 16 characters"; continue; fi
      ask_secret "Once more"
      [ "$ANSWER" = "$pw" ] && break
      problem "the two differ"
    done
  else
    ok "Firefly III has its account already, so no password is asked"
  fi

  for entry in "${TOKENS[@]}"; do
    key="${entry%%:*}"
    name="${entry#*:}"
    if [ "$users" != 0 ] && token_works "${!key:-}"; then
      ok "$key works"
    else
      mint+=("$name")
    fi
  done
  if [ "${#mint[@]}" -gt 0 ] || [ -n "$pw" ]; then
    # The password goes to jq on stdin, and from there on stdin into the container.
    request="$(printf '%s' "$pw" | jq -Rsc --arg email "$SITE_OWNER" '$ARGS.positional as $t
      | {email: $email, password: ., tokens: $t}' --args "${mint[@]}")"
    pw=""
    answer="$(bootstrap <<<"$request")"
    request=""
    [ "$(jq -r .user <<<"$answer")" != created ] || ok "the account $SITE_OWNER is made"
    for entry in "${TOKENS[@]}"; do
      key="${entry%%:*}"
      name="${entry#*:}"
      token="$(jq -r --arg n "$name" '.tokens[$n].token // empty' <<<"$answer")"
      [ -n "$token" ] || continue
      put "$key" "$token" || die "Firefly III made a token for $name that $key does not take"
      ok "$key: a new token, \"$name\" in Firefly III, valid until $(jq -r --arg n "$name" '.tokens[$n].expires_at' <<<"$answer" | cut -c1-10)"
    done
    reload
  fi
  for entry in "${TOKENS[@]}"; do
    key="${entry%%:*}"
    token_works "${!key:-}" || die "Firefly III does not accept the new $key"
  done
  registration closed || die "Firefly III's /register still shows its form"
  ok "/register is closed: no one else can make an account"
}

# ---------------------------------------------------------------- start ---
agent_on() { systemctl is-enabled --quiet fireflyx-deploy.timer 2>/dev/null; }

check_certificates() {
  local host pending=() still=() _
  if is_localhost "${DOMAIN:-}"; then
    ok "*.localhost has Caddy's own certificates, which no browser trusts; not checked"
    return 0
  fi
  if [ -n "${ACME_CA:-}" ]; then
    say "ACME_CA is set, so the certificates come from $ACME_CA; not checked."
    return 0
  fi
  mapfile -t pending < <(names "${DOMAIN:-}")
  say "Waiting for Let's Encrypt to give each name its certificate, up to three minutes."
  for _ in $(seq 18); do
    still=()
    for host in "${pending[@]}"; do
      # To this server's own Caddy, checked against the system's trusted CAs.
      if curl -sS -o /dev/null --max-time 10 --resolve "$host:443:127.0.0.1" "https://$host/" 2>/dev/null; then
        ok "https://$host has its certificate"
      else
        still+=("$host")
      fi
    done
    pending=("${still[@]}")
    [ "${#pending[@]}" -gt 0 ] || return 0
    sleep 10
  done
  problem "no certificate after three minutes: ${pending[*]}. Caddy says:"
  compose logs --no-log-prefix --since 10m caddy 2>&1 | grep -iE '"level":"error"|challenge failed' | tail -n 4 | cut -c1-300 | sed 's/^/     /' || true
  say "Look at the DNS records (scripts/firefly-pocket setup domain), then scripts/firefly-pocket setup start."
  return 1
}

step_start() {
  heading "Start"
  # Caddy makes Firefly III public, and until its account exists anyone could claim it.
  has IMPORTER_FIREFLY_TOKEN || die "the account comes first: scripts/firefly-pocket setup account"
  generate
  reload
  if agent_on; then
    say "The deploy agent runs this server, so it applies the settings: scripts/deploy.sh --force."
    "$REPO_ROOT/scripts/deploy.sh" --force || die "the deploy failed; what it said is above"
    reload
  else
    say "Pulling the images and starting every service. The first time takes a few minutes."
    compose pull --quiet --ignore-buildable
    compose up -d --no-build --remove-orphans
    local out
    out="$(smoke_test)" || { problem "$out"; die "not everything runs: docker compose --project-directory compose ps -a"; }
    ok "$out"
  fi
  check_certificates || SKIPPED+=("certificates: scripts/firefly-pocket setup start")
}

# ----------------------------------------------------------------- bank ---
# A key for a new application, made here, and the certificate to upload with it.
# The private key never leaves this server: it goes into the store, the
# certificate (public) into compose/secrets/eb/.
make_eb_key() {
  local b64
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$WORK/eb.pem" 2>/dev/null
  openssl req -new -x509 -key "$WORK/eb.pem" -days 3650 -subj "/CN=$NEXT_HOSTNAME" -out "$WORK/eb.crt" 2>/dev/null
  b64="$(grep -v -- '-----' "$WORK/eb.pem" | tr -d '\n\r')"
  rm -f "$WORK/eb.pem"
  put ENABLE_BANKING_PRIVATE_KEY "$b64" || die "the new key does not pass its check"
  ! has ENABLE_BANKING_APP_ID || drop ENABLE_BANKING_APP_ID
  mkdir -p "$(dirname "$EB_CERT")"
  install -m 644 "$WORK/eb.crt" "$EB_CERT"
  reload
}

step_bank() {
  heading "Bank import (Enable Banking)"
  reload
  say "Firefly Pocket imports from your bank through Enable Banking (enablebanking.com), free for" \
      "your own accounts. Check first that it covers your bank."
  if has ENABLE_BANKING_APP_ID; then
    ok "the application is $ENABLE_BANKING_APP_ID; Enter keeps it"
  elif ! confirm "Set it up now?" y; then
    say "Skipped: scripts/firefly-pocket setup bank, any time."
    SKIPPED+=("bank import: scripts/firefly-pocket setup bank")
    return 0
  fi
  if has ENABLE_BANKING_PRIVATE_KEY && [ ! -f "$EB_CERT" ]; then
    say "Its key was set by hand (scripts/set-eb-key.sh), for an application of its own."
    if ! confirm "Keep it?" y; then make_eb_key; fi
  elif ! has ENABLE_BANKING_PRIVATE_KEY; then
    make_eb_key
  fi
  if [ -f "$EB_CERT" ] && ! has ENABLE_BANKING_APP_ID; then
    say "" "In Enable Banking's control panel, register a new application:" \
        "  - Environment: production. A sandbox application only ever sees a mock bank." \
        "  - Its public key: upload this certificate, made here for it (the private key stays on this server)," \
        "      $EB_CERT" \
        "    copied to your computer with" \
        "      scp $(id -un)@${FIREFLY_HOSTNAME}:$EB_CERT ." \
        "  - Redirect URLs, both:" \
        "      https://$NEXT_HOSTNAME/eb-callback" \
        "      https://$IMPORT_HOSTNAME/eb-callback" \
        "  - Privacy policy https://$LEGAL_HOSTNAME/privacy, terms https://$LEGAL_HOSTNAME/terms" \
        "  - Then activate it by linking your own accounts (restricted mode, free for personal use)." \
        "The certificate, if you would rather paste it:"
    sed 's/^/     /' "$EB_CERT"
  fi
  local id kept="${ENABLE_BANKING_APP_ID:-}" pem="$WORK/check.pem"
  while :; do
    if [ -n "$kept" ]; then ask "Application ID (Enter keeps it)" "$kept"; else ask "Application ID (Enter to skip)"; fi
    id="$ANSWER"
    if [ -z "$id" ]; then
      say "Skipped: scripts/firefly-pocket setup bank, once the application is registered."
      SKIPPED+=("bank import: scripts/firefly-pocket setup bank")
      return 0
    fi
    "$FP" config check ENABLE_BANKING_APP_ID "$id" 2>/dev/null || { problem "an application ID looks like 1b4e28ba-2fa1-11d2-883f-0016d3cca427"; continue; }
    # The key as the importer rebuilds it from the store, for set-eb-key.sh's
    # signed request. set-eb-key.sh keeps the ID before it asks.
    { echo "-----BEGIN PRIVATE KEY-----"; fold -w64 <<<"$ENABLE_BANKING_PRIVATE_KEY"; echo "-----END PRIVATE KEY-----"; } > "$pem"
    if FROM_SETUP=1 "$REPO_ROOT/scripts/set-eb-key.sh" "$pem" "$id" 2>&1 | sed 's/^/   /'; then
      rm -f "$pem"
      reload
      ok "Enable Banking accepts a request signed with this key: link a bank from Firefly Pocket, Bank connections"
      return 0
    fi
    rm -f "$pem"
    if [ -n "$kept" ]; then put ENABLE_BANKING_APP_ID "$kept"; else drop ENABLE_BANKING_APP_ID; fi
    reload
    problem "not confirmed (above). With HTTP 000 Enable Banking did not answer; with any other, the ID is not" \
            "that of the application registered with this key's certificate"
    if ! confirm "Try another ID?" y; then
      SKIPPED+=("bank import: scripts/firefly-pocket setup bank")
      return 0
    fi
  done
}

# ---------------------------------------------------------- suggestions ---
# model_check anthropic|gemini <key> <model>: the provider lists the model for the key.
model_check() {
  local code
  if [ "$1" = anthropic ]; then
    code="$(curl_with "x-api-key: $2" -H 'anthropic-version: 2026-10-21' "https://api.anthropic.com/v1/models/$3")"
  else
    code="$(curl_with "x-goog-api-key: $2" "https://generativelanguage.googleapis.com/v1beta/models/$3")"
  fi
  [ "$code" = 200 ] && return 0
  problem "$1 answered $code: $(jq -r '.error.message // .error // empty' "$WORK/body" 2>/dev/null | head -c 300 || true)"
  [ "$code" != 404 ] || problem "no model $3 for this key"
  return 1
}

step_suggestions() {
  heading "Category suggestions"
  reload
  say "Each night an AI model suggests a category for each new transaction, as a rule you approve in" \
      "Firefly Pocket. It needs an API key: Anthropic's (console.anthropic.com, an account with" \
      "credit) or Gemini's (a paid project: the free tier allows 20 requests a day)."
  local model="${SUGGESTER_MODEL:-claude-haiku-5-5}" provider key current
  if [[ "$model" == gemini-* ]]; then current="${GEMINI_API_KEY:-}"; else current="${ANTHROPIC_API_KEY:-}"; fi
  while :; do
    if [ -n "$current" ]; then
      ask_secret "API key (Enter keeps ...${current: -4})"
    else
      ask_secret "API key (Enter to skip)"
    fi
    key="${ANSWER:-$current}"
    if [ -z "$key" ]; then
      say "Skipped: scripts/firefly-pocket setup suggestions, any time."
      SKIPPED+=("category suggestions: scripts/firefly-pocket setup suggestions")
      return 0
    fi
    case "$key" in
      sk-ant-*) provider=anthropic ;;
      AIza*) provider=gemini ;;
      *) if confirm "Is it a Gemini key? (no: Anthropic)" n; then provider=gemini; else provider=anthropic; fi ;;
    esac
    if [ "$provider" = anthropic ]; then
      [[ "$model" == claude-* ]] || model=claude-haiku-5-5
    elif [[ "$model" != gemini-* ]]; then
      ask "Gemini model, as Google names it (ai.google.dev/gemini-api/docs/models)"
      model="$ANSWER"
    fi
    "$FP" config check SUGGESTER_MODEL "$model" 2>/dev/null || { problem "$model is no model name"; model="${SUGGESTER_MODEL:-claude-haiku-5-5}"; continue; }
    if model_check "$provider" "$key" "$model"; then break; fi
    current=""
  done
  if [ "$provider" = anthropic ]; then put ANTHROPIC_API_KEY "$key"; else put GEMINI_API_KEY "$key"; fi || die "the key does not pass its check"
  [ "$model" = "$(get SUGGESTER_MODEL)" ] || put SUGGESTER_MODEL "$model"
  reload
  ok "$provider has $model for this key"
}

# --------------------------------------------------------------- alerts ---
# hc_check <api-key> <name> <cron> <what>: a healthchecks.io check, made or found
# by its name; its ping URL on stdout.
hc_check() {
  local body code
  body="$(jq -cn --arg name "$2" --arg schedule "$3" --arg tz "$TZ" --arg desc "$4" \
    '{name: $name, schedule: $schedule, tz: $tz, grace: 3600, channels: "*", unique: ["name"], tags: "firefly-pocket", desc: $desc}')"
  code="$(curl_with "X-Api-Key: $1" -H 'Content-Type: application/json' --data "$body" https://healthchecks.io/api/v3/checks/)"
  if [ "$code" != 200 ] && [ "$code" != 201 ]; then
    problem "healthchecks.io answered $code: $(jq -r '.error // empty' "$WORK/body" 2>/dev/null | head -c 200 || true)" >&2
    return 1
  fi
  jq -er '.ping_url // empty' "$WORK/body" || { problem "healthchecks.io gave no ping URL" >&2; return 1; }
}

step_alerts() {
  heading "Alerts"
  reload
  say "When something fails (an import, a backup, a bank consent about to end), an alert goes to the" \
      "Firefly Pocket app on your phone, and to ntfy (ntfy.sh), which works even when Firefly Pocket does not."
  local url="${NTFY_URL:-https://ntfy.sh/firefly-pocket-$(randstr 24)}"
  [ -n "${NTFY_URL:-}" ] || say "A topic was made for this server. Anyone who knows its name can read what goes to it," \
                                "so the name is long and random: keep it to yourself."
  while :; do
    ask "ntfy topic URL (none for no ntfy)" "$url"
    if [ "$ANSWER" = none ]; then
      ! has NTFY_URL || drop NTFY_URL
      say "No ntfy: alerts reach only the Firefly Pocket app."
      SKIPPED+=("ntfy alerts: scripts/firefly-pocket setup alerts")
      break
    fi
    put NTFY_URL "$ANSWER" || continue
    url="$ANSWER"
    say "Subscribe to it: in the ntfy app (Android, iOS), Subscribe to topic, ${url##*/}" \
        "(on ${url%/*}); or open $url in a browser."
    while confirm "Send a test alert?" y; do
      if curl -fsS --max-time 20 -o /dev/null -H "Title: Firefly Pocket: test" \
          -d "Alerts from $(hostname) arrive here." "$url"; then
        confirm "Did it arrive?" y && break 2
        say "Look at the topic you subscribed to: ${url##*/}."
      else
        problem "ntfy did not take it"
      fi
    done
    break
  done

  say "" "A dead man's switch: every alert above is sent from this server, so when it is down nothing" \
      "alerts at all. healthchecks.io (free) mails you when the nightly import or the backup does not" \
      "report in on time. Its API key makes both checks: your project's Settings, API Access, the" \
      "read-write key. The key is used once, not kept."
  [ -z "${HEALTHCHECK_NIGHTLY_URL:-}" ] || [ -z "${HEALTHCHECK_BACKUP_URL:-}" ] || ok "both checks are set; Enter keeps them"
  local nightly backup
  while :; do
    ask_secret "healthchecks.io API key (Enter to $( [ -n "${HEALTHCHECK_NIGHTLY_URL:-}" ] && echo keep || echo skip))"
    if [ -z "$ANSWER" ]; then
      [ -n "${HEALTHCHECK_NIGHTLY_URL:-}" ] || SKIPPED+=("the dead man's switch: scripts/firefly-pocket setup alerts")
      return 0
    fi
    nightly="$(hc_check "$ANSWER" "Firefly Pocket nightly" "0 3 * * *" "scripts/nightly.sh on $(hostname): the bank import")" || continue
    backup="$(hc_check "$ANSWER" "Firefly Pocket backup" "0 2 * * *" "scripts/backup.sh on $(hostname)")" || continue
    break
  done
  ANSWER=""
  if ! put HEALTHCHECK_NIGHTLY_URL "$nightly" || ! put HEALTHCHECK_BACKUP_URL "$backup"; then
    die "healthchecks.io gave ping URLs that do not pass their check"
  fi
  reload
  for url in "$nightly" "$backup"; do
    curl -fsS --max-time 10 -o /dev/null --data-raw "set up by firefly-pocket setup" "$url" || problem "the first ping to $url failed"
  done
  ok "both checks made, with their schedules in $TZ, and pinged once"
}

# -------------------------------------------------------------- backups ---
restic_password_note() {
  say "" "Keep the repository's password off this server, in your password manager: without it" \
      "nobody can read the offsite copy, you included, once this server is gone." \
      "    $RESTIC_PASSWORD"
  ask "Saved it? Enter to go on"
}

step_backups() {
  heading "Offsite backups"
  reload
  say "At 02:00 each night the databases and attachments are backed up here, and with a restic" \
      "repository also offsite. Without one, losing this server loses everything. S3 storage" \
      "(Backblaze B2, Hetzner Object Storage, AWS) also needs its access key. Such as" \
      "    s3:https://s3.eu-central-003.backblazeb2.com/your-bucket/firefly-pocket"
  local repo="${RESTIC_REPOSITORY:-}" out
  while :; do
    ask "restic repository (Enter to skip)" "$repo"
    if [ -z "$ANSWER" ]; then
      say "Skipped: scripts/firefly-pocket setup backups, any time."
      SKIPPED+=("offsite backups: scripts/firefly-pocket setup backups")
      return 0
    fi
    if ! command -v restic >/dev/null 2>&1; then
      problem "restic is not installed: sudo apt-get install -y restic, then scripts/firefly-pocket setup backups"
      SKIPPED+=("offsite backups: scripts/firefly-pocket setup backups")
      return 0
    fi
    "$FP" config check RESTIC_REPOSITORY "$ANSWER" 2>/dev/null || { problem "one word, without spaces"; continue; }
    put RESTIC_REPOSITORY "$ANSWER" || continue
    repo="$ANSWER"
    if [[ "$repo" == s3:* ]]; then
      until ask_setting AWS_ACCESS_KEY_ID "Access key ID" "${AWS_ACCESS_KEY_ID:-}"; do problem "S3 needs it"; done
      while :; do
        ask_secret "Secret access key${AWS_SECRET_ACCESS_KEY:+ (Enter keeps ...${AWS_SECRET_ACCESS_KEY: -4})}"
        [ -n "$ANSWER" ] || { [ -n "${AWS_SECRET_ACCESS_KEY:-}" ] && break; problem "S3 needs it"; continue; }
        put AWS_SECRET_ACCESS_KEY "$ANSWER" && break
      done
    fi
    reload
    # restic reads RESTIC_REPOSITORY, RESTIC_PASSWORD and the AWS keys from the
    # environment, as lib.sh exported them from .env.
    if out="$(timeout 120 restic cat config 2>&1)"; then
      ok "the repository opens: $(timeout 120 restic snapshots --json 2>/dev/null | jq length 2>/dev/null || echo "?") snapshots in it"
      return 0
    fi
    if grep -qiE 'wrong password|no key found' <<<"$out"; then
      problem "that repository has another password than the one made here"
      ask_secret "Its password (Enter to give up)"
      if [ -n "$ANSWER" ] && put RESTIC_PASSWORD "$ANSWER"; then
        ANSWER=""
        continue
      fi
      ANSWER=""
      SKIPPED+=("offsite backups: scripts/firefly-pocket setup backups")
      return 0
    elif grep -qiE 'does not exist|Is there a repository|unable to open config' <<<"$out"; then
      if confirm "Nothing is there yet. Make a restic repository there?" y; then
        if out="$(timeout 300 restic init 2>&1)"; then
          ok "repository made"
          restic_password_note
          return 0
        fi
        problem "restic init failed: $(tail -n 2 <<<"$out")"
      fi
    else
      problem "restic cannot open it: $(tail -n 3 <<<"$out" | cut -c1-300)"
    fi
  done
}

# -------------------------------------------------------------- updates ---
step_updates() {
  heading "Updates"
  if agent_on; then
    ok "the deploy agent is on: it deploys every merge into master within two minutes"
    return 0
  fi
  say "The deploy agent keeps this server on master of $(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "this repository"):" \
      "it deploys every merge into it within two minutes, and its first run installs the nightly" \
      "jobs: the import, the backup, the restore tests (README \"Deploying\")."
  if confirm "Turn it on?" y; then
    REPO_DIR="$REPO_ROOT" "$REPO_ROOT/scripts/install-deploy-agent.sh" | sed 's/^/   /'
  else
    problem "off: nothing runs on a schedule, so no nightly import and no backup"
    SKIPPED+=("the deploy agent and the nightly jobs: scripts/firefly-pocket setup updates")
  fi
}

summary() {
  heading "Firefly Pocket is set up"
  say "Firefly III      https://$FIREFLY_HOSTNAME" \
      "                 sign in as $SITE_OWNER, then turn on two-factor authentication: Options, Profile" \
      "Firefly Pocket   https://$NEXT_HOSTNAME" \
      "                 it asks for a token: in Firefly III, Options, Profile, OAuth, Personal Access" \
      "                 Tokens, Create one named after the phone. Then add it to the home screen" \
      "Bank importer    https://$IMPORT_HOSTNAME, user $IMPORT_AUTH_USER, the password shown before"
  if [ "${#SKIPPED[@]}" -gt 0 ]; then
    say "" "Left for later:"
    printf '     - %s\n' "${SKIPPED[@]}"
  fi
  say "" "Change any answer with scripts/firefly-pocket setup <step> ($STEPS);" \
      "scripts/firefly-pocket config list shows every setting."
}

# ----------------------------------------------------------------- main ---
command -v docker >/dev/null 2>&1 || die "docker is not installed"
if [ ! -f "$CONFIG" ] && [ -f "$COMPOSE_DIR/.env" ]; then
  die "compose/.env is still edited by hand. Move it into the settings store first, once: scripts/firefly-pocket config import"
fi

case "${1:-}" in
  "")
    say "Firefly Pocket setup: a few questions, each checked as you answer. Run it again to change" \
        "an answer; Enter keeps what is there."
    for step in domain you account start bank suggestions alerts backups start updates; do
      "step_$step"
    done
    summary
    ;;
  domain | you | account | bank | suggestions | alerts | backups)
    [ -f "$CONFIG" ] || [ "$1" = domain ] || die "nothing is set up yet: run scripts/firefly-pocket setup"
    "step_$1"
    [ "$1" = domain ] && [ ! -f "$COMPOSE_DIR/.env" ] || step_start
    ;;
  start | updates)
    [ -f "$CONFIG" ] || die "nothing is set up yet: run scripts/firefly-pocket setup"
    "step_$1"
    ;;
  *)
    sed -n '3,30s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
    exit 2
    ;;
esac
