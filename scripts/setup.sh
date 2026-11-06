#!/usr/bin/env bash
#
# Firefly Pocket's setup wizard (Setup UI step 2). On the server, over SSH:
#
#     scripts/firefly-pocket setup            every step, in order
#     scripts/firefly-pocket setup <step>     one step again, then start
#     scripts/firefly-pocket setup web        start in a browser instead (below)
#
# Each step asks only for what you have to give, checks it, and keeps it in the
# settings store (scripts/config.sh); everything else is generated, the Firefly
# III tokens included. Run it again to change an answer: Enter keeps what is
# there. compose/.env is written from the store, so nobody opens it.
#
#   domain       the domain, and that each of its five names resolves to this server
#   you          your email, your name for the legal pages and the timezone; then
#                every secret is generated (gen-secrets.sh)
#   account      your Firefly III account and a token for each app, made inside
#                Firefly III (scripts/firefly-bootstrap.php, through account.sh, which
#                the console's account step uses too); /register is closed after
#   start        every service started (by the deploy agent, once it runs), and each
#                name's certificate checked
#   bank         Enable Banking: a key and certificate made here for the application
#                you register, then its ID, checked with a signed request (bank.sh,
#                which the console's bank step uses too)
#   suggestions  an Anthropic or Gemini key, checked by asking for the model (suggestions.sh)
#   alerts       an ntfy topic made here and tested; healthchecks.io checks made with its API key
#                (alerts.sh)
#   backups      a restic repository, opened or created; its password shown to keep
#                (backups.sh, which the console's backups step uses too)
#   updates      the deploy agent (scripts/install-deploy-agent.sh), which keeps this
#                server on master and installs the nightly jobs; the console's turns it
#                on too, where sudo needs no password
#   finish       ends setup web's setup code, if there is one (below)
#
# The full run starts the stack once the account exists, so nothing is public
# before then, and again at the end with every answer; then it finishes setup.
# Answers are read from stdin when it is not a terminal, one line each, which is
# how the boot test runs it (scripts/boot-test.sh).
#
# setup web asks only for the domain and your email, which Caddy needs, makes a
# setup code and starts Caddy and the Firefly Pocket Console alone. Until Firefly
# III has its account, every name then shows only the console, at
# https://admin.<domain>, which asks for that code (the Caddyfile's setup gate).
# Its pages are the domain and you steps, then the account and start steps, then
# the bank, suggestions, alerts, backups and updates steps, and Finish. The code
# works until setup finishes: the console's Finish, or this wizard's full run or
# finish step, ends it. What the console saves, scripts/console.sh applies: setup
# web installs the systemd unit that runs it, unless FIREFLY_POCKET_NO_SYSTEMD is
# set (CI).

set -euo pipefail
shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/compose"
CONFIG="$COMPOSE_DIR/config.json"
# shellcheck source=host.sh
source "$REPO_ROOT/scripts/host.sh"
FP="$REPO_ROOT/scripts/firefly-pocket"
STEPS="domain you account start bank suggestions alerts backups updates"
# The account and the apps' tokens (TOKENS, firefly_up, make_tokens), Enable
# Banking's key and check (EB_CERT, make_eb_key, eb_check), the AI key's check
# (model_check) and the alerts' (ntfy_send, hc_setup), shared with the
# console's steps.
# shellcheck source=account.sh
source "$REPO_ROOT/scripts/account.sh"
# shellcheck source=bank.sh
source "$REPO_ROOT/scripts/bank.sh"
# shellcheck source=suggestions.sh
source "$REPO_ROOT/scripts/suggestions.sh"
# shellcheck source=alerts.sh
source "$REPO_ROOT/scripts/alerts.sh"
# shellcheck source=backups.sh
source "$REPO_ROOT/scripts/backups.sh"

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

# The five names, as compose and lib.sh derive them: <name>.<domain> unless one
# is set on its own. One with neither is left out (without a domain, the
# console's has no name until ADMIN_HOSTNAME is set).
names() {
  local domain="$1" pair value
  for pair in ADMIN_HOSTNAME:admin FIREFLY_HOSTNAME:firefly NEXT_HOSTNAME:app IMPORT_HOSTNAME:import LEGAL_HOSTNAME:legal; do
    value="$(stored "${pair%%:*}")"
    value="${value:-${domain:+${pair#*:}.$domain}}"
    [ -z "$value" ] || printf '%s\n' "$value"
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

# --------------------------------------------------------------- domain ---
# my_address, private_v4 and host_timezone are in host.sh.

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
  say "Firefly Pocket answers on five names under a domain of yours: firefly.<domain> is Firefly III," \
      "app.<domain> Firefly Pocket, admin.<domain> its console, import.<domain> the bank importer," \
      "and legal.<domain> the privacy policy and terms. A subdomain works too, such as" \
      "money.example.com. Point one wildcard record at this server first:" \
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
        ok "no domain: each name is set on its own ($(names "" | paste -sd' ' -))"
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

# Your email. The others follow it, unless one was set to something else on
# purpose; scripts/console.sh does the same with what the console saves.
ask_email() {
  local old acme vapid
  old="$(get SITE_OWNER)"
  say "One email address of yours: your Firefly III account's, Let's Encrypt's for certificate" \
      "notices, the push services' contact, and the legal pages'."
  until ask_setting SITE_OWNER "Email" "$old"; do problem "an email address is needed"; done
  acme="$(get ACME_EMAIL)"
  if [ -z "$acme" ] || [ "$acme" = "$old" ]; then put ACME_EMAIL "$ANSWER"; fi
  vapid="$(get VAPID_SUBJECT)"
  if [ -z "$vapid" ] || [ "$vapid" = "mailto:$old" ]; then put VAPID_SUBJECT "mailto:$ANSWER"; fi
}

step_you() {
  heading "You"
  ask_email

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
# firefly_up and make_tokens are in account.sh.
step_account() {
  heading "Your Firefly III account"
  generate
  reload
  say "Postgres and Firefly III first. Caddy, which makes them public, starts only once the account" \
      "exists, so no one else can claim it. The first start sets up the database: a minute or two."
  firefly_up
  local pw=""
  if [ "$USERS" = 0 ]; then
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
    ANSWER=""
  else
    ok "Firefly III has its account already, so no password is asked"
  fi
  make_tokens "$pw"
}

# ---------------------------------------------------------------- start ---

# check_certificates [<host>...]: every name, or those given.
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
  if [ $# -gt 0 ]; then pending=("$@"); else mapfile -t pending < <(names "${DOMAIN:-}"); fi
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
    # The console's directories, made by this user before compose would make them as root.
    "$FP" console status
    compose up -d --no-build --remove-orphans
    local out
    out="$(smoke_test)" || { problem "$out"; die "not everything runs: docker compose --project-directory compose ps -a"; }
    ok "$out"
  fi
  check_certificates || SKIPPED+=("certificates: scripts/firefly-pocket setup start")
}

# ------------------------------------------------------------------ web ---
# The setup code: 16 characters of Crockford's base32 (no I, L, O or U), 80 bits,
# in groups of four. Asked for by the console until setup is finished.
make_setup_code() {
  local raw=""
  while [ "${#raw}" -lt 16 ]; do
    raw="$raw$(LC_ALL=C head -c 256 /dev/urandom | LC_ALL=C tr -dc '0-9A-HJKMNP-TV-Z')"
  done
  printf '%s-%s-%s-%s' "${raw:0:4}" "${raw:4:4}" "${raw:8:4}" "${raw:12:4}"
}

step_web() {
  heading "Setup in the browser"
  if has IMPORTER_FIREFLY_TOKEN 2>/dev/null; then
    if ! has SETUP_CODE; then
      ok "setup is finished: Firefly III has its account and there is no setup code, so the console has nothing to set up"
      say "Change an answer with scripts/firefly-pocket setup <step> ($STEPS)."
      return 0
    fi
    reload
    heading "Open https://$ADMIN_HOSTNAME"
    say "and enter the setup code:" "" "    $SETUP_CODE" "" \
        "Firefly III has its account, so every name is open; the console has the bank connection," \
        "suggestions and alerts left, then Finish, which ends this code. scripts/firefly-pocket setup" \
        "finish ends it here."
    return 0
  fi
  say "The console asks for the rest of the server and makes your Firefly III account, at" \
      "https://admin.<domain>. It needs the domain first, and an email for Let's Encrypt, so Caddy" \
      "can get its certificate."
  step_domain
  heading "You"
  ask_email
  generate
  has SETUP_CODE || printf '%s\n' "$(make_setup_code)" | "$FP" config set --no-render SETUP_CODE - >/dev/null
  reload

  heading "The console"
  if [ -n "${FIREFLY_POCKET_NO_SYSTEMD:-}" ]; then
    say "FIREFLY_POCKET_NO_SYSTEMD is set, so nothing applies what the console saves by itself:" \
        "scripts/firefly-pocket console apply does, each time."
  else
    say "A systemd unit applies what the console saves, as soon as it saves it (sudo):"
    "$FP" console install | sed 's/^/   /'
  fi
  "$FP" console status
  say "Starting Caddy and the console, and nothing else. Until your Firefly III account exists," \
      "every other name sends the browser to the console."
  compose up -d --no-build --no-deps --quiet-pull caddy console
  check_certificates "$ADMIN_HOSTNAME" || SKIPPED+=("the console's certificate: scripts/firefly-pocket setup web")

  heading "Open https://$ADMIN_HOSTNAME"
  say "and enter the setup code:" "" "    $SETUP_CODE" "" \
      "Run this again to see it. It works until setup is finished: the console's last page ends it." \
      "Then scripts/firefly-pocket setup for the rest: Enter keeps what the console saved."
  if [ "${#SKIPPED[@]}" -gt 0 ]; then
    say "" "Left for later:"
    printf '     - %s\n' "${SKIPPED[@]}"
  fi
}

# ----------------------------------------------------------------- bank ---
# A key for a new application, made here, and the certificate to upload with it
# (bank.sh). The private key never leaves this server: it goes into the store,
# the certificate (public) into compose/secrets/eb/.
new_eb_key() {
  make_eb_key "$WORK" || die "$EB_PROBLEM"
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
  if has ENABLE_BANKING_PRIVATE_KEY && ! eb_cert_matches "${ENABLE_BANKING_PRIVATE_KEY:-}"; then
    say "Its key was set by hand (scripts/set-eb-key.sh), for an application of its own."
    if ! confirm "Keep it?" y; then new_eb_key; fi
  elif ! has ENABLE_BANKING_PRIVATE_KEY; then
    new_eb_key
  fi
  if eb_cert_matches "${ENABLE_BANKING_PRIVATE_KEY:-}" && ! has ENABLE_BANKING_APP_ID; then
    local urls
    mapfile -t urls < <(eb_redirect_urls | sed 's/^/      /')
    say "" "In Enable Banking's control panel, register a new application:" \
        "  - Environment: production. A sandbox application only ever sees a mock bank." \
        "  - Its public key: upload this certificate, made here for it (the private key stays on this server)," \
        "      $EB_CERT" \
        "    copied to your computer with" \
        "      scp $(id -un)@${FIREFLY_HOSTNAME}:$EB_CERT ." \
        "  - Redirect URLs, both:" \
        "${urls[@]}" \
        "  - Privacy policy https://$LEGAL_HOSTNAME/privacy, terms https://$LEGAL_HOSTNAME/terms" \
        "  - Then activate it by linking your own accounts (restricted mode, free for personal use)." \
        "The certificate, if you would rather paste it:"
    sed 's/^/     /' "$EB_CERT"
  fi
  local id kept="${ENABLE_BANKING_APP_ID:-}" note
  while :; do
    if [ -n "$kept" ]; then ask "Application ID (Enter keeps it)" "$kept"; else ask "Application ID (Enter to skip)"; fi
    id="$ANSWER"
    if [ -z "$id" ]; then
      say "Skipped: scripts/firefly-pocket setup bank, once the application is registered."
      SKIPPED+=("bank import: scripts/firefly-pocket setup bank")
      return 0
    fi
    "$FP" config check ENABLE_BANKING_APP_ID "$id" 2>/dev/null || { problem "an application ID looks like 1b4e28ba-2fa1-11d2-883f-0016d3cca427"; continue; }
    # Kept only once Enable Banking takes a request signed with the key for it.
    if eb_check "${ENABLE_BANKING_PRIVATE_KEY:-}" "$id"; then
      put ENABLE_BANKING_APP_ID "$id" || die "config set refused the ID it had checked"
      reload
      ok "Enable Banking accepts a request signed with this key for $(eb_about)"
      while IFS= read -r note; do problem "$note"; done < <(eb_notes)
      ok "link a bank from Firefly Pocket: Bank connections"
      return 0
    fi
    problem "$(eb_refusal)"
    if ! confirm "Try another ID?" y; then
      SKIPPED+=("bank import: scripts/firefly-pocket setup bank")
      return 0
    fi
  done
}

# ---------------------------------------------------------- suggestions ---
step_suggestions() {
  heading "Category suggestions"
  reload
  say "Each night an AI model suggests a category for each new transaction, as a rule you approve in" \
      "Firefly Pocket. It needs an API key: Anthropic's (console.anthropic.com, an account with" \
      "credit) or Gemini's (a paid project: the free tier allows 20 requests a day)."
  local model="${SUGGESTER_MODEL:-$SUGGESTER_DEFAULT_MODEL}" provider key current
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
    provider="$(key_provider "$key")"
    if [ -z "$provider" ]; then
      if confirm "Is it a Gemini key? (no: Anthropic)" n; then provider=gemini; else provider=anthropic; fi
    fi
    if [ "$provider" = anthropic ]; then
      [[ "$model" == claude-* ]] || model="$SUGGESTER_DEFAULT_MODEL"
    elif [[ "$model" != gemini-* ]]; then
      ask "Gemini model, as Google names it (ai.google.dev/gemini-api/docs/models)"
      model="$ANSWER"
    fi
    "$FP" config check SUGGESTER_MODEL "$model" 2>/dev/null || { problem "$model is no model name"; model="${SUGGESTER_MODEL:-$SUGGESTER_DEFAULT_MODEL}"; continue; }
    if model_check "$provider" "$key" "$model"; then break; fi
    problem "$MODEL_PROBLEM"
    current=""
  done
  if [ "$provider" = anthropic ]; then put ANTHROPIC_API_KEY "$key"; else put GEMINI_API_KEY "$key"; fi || die "the key does not pass its check"
  [ "$model" = "$(get SUGGESTER_MODEL)" ] || put SUGGESTER_MODEL "$model"
  reload
  ok "$provider has $model for this key"
}

# --------------------------------------------------------------- alerts ---
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
      if ntfy_send "$url" "Firefly Pocket: test" "Alerts from $(hostname) arrive here."; then
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
  while :; do
    ask_secret "healthchecks.io API key (Enter to $( [ -n "${HEALTHCHECK_NIGHTLY_URL:-}" ] && echo keep || echo skip))"
    if [ -z "$ANSWER" ]; then
      [ -n "${HEALTHCHECK_NIGHTLY_URL:-}" ] || SKIPPED+=("the dead man's switch: scripts/firefly-pocket setup alerts")
      return 0
    fi
    hc_setup "$ANSWER" && break
    problem "$HC_PROBLEM"
  done
  ANSWER=""
  if ! put HEALTHCHECK_NIGHTLY_URL "$HC_NIGHTLY" || ! put HEALTHCHECK_BACKUP_URL "$HC_BACKUP"; then
    die "healthchecks.io gave ping URLs that do not pass their check"
  fi
  reload
  local url
  for url in "$HC_NIGHTLY" "$HC_BACKUP"; do
    hc_ping "$url" "set up by firefly-pocket setup" || problem "the first ping to one of the checks failed"
  done
  ok "both checks made, with their schedules in $TZ, and pinged once"
}

# -------------------------------------------------------------- backups ---
# restic_password_note <password>
restic_password_note() {
  say "" "Keep the repository's password off this server, in your password manager: without it" \
      "nobody can read the offsite copy, you included, once this server is gone." \
      "    $1"
  ask "Saved it? Enter to go on"
}

# The repository, its S3 keys and its password are kept once it opens, as the
# console's step keeps them (console.sh): nothing that does not work replaces
# what does.
step_backups() {
  heading "Offsite backups"
  reload
  say "At 02:00 each night the databases and attachments are backed up here, and with a restic" \
      "repository also offsite. Without one, losing this server loses everything. S3 storage" \
      "(Backblaze B2, Hetzner Object Storage, AWS) also needs its access key. Such as" \
      "    s3:https://s3.eu-central-003.backblazeb2.com/your-bucket/firefly-pocket"
  local enter="Enter to skip" repo key_id secret password made
  [ -z "${RESTIC_REPOSITORY:-}" ] || enter="Enter keeps it"
  while :; do
    ask "restic repository ($enter)" "${RESTIC_REPOSITORY:-}"
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
    "$FP" config check RESTIC_REPOSITORY - <<<"$ANSWER" >/dev/null 2>&1 || { problem "one word, without spaces"; continue; }
    repo="$ANSWER" key_id="" secret="" password="$RESTIC_PASSWORD" made=""
    if [[ "$repo" == s3:* ]]; then
      while :; do
        ask "Access key ID" "${AWS_ACCESS_KEY_ID:-}"
        key_id="$ANSWER"
        [ -n "$key_id" ] || { problem "S3 needs it"; continue; }
        "$FP" config check AWS_ACCESS_KEY_ID - <<<"$key_id" >/dev/null 2>&1 && break
        problem "no spaces"
      done
      while :; do
        ask_secret "Secret access key${AWS_SECRET_ACCESS_KEY:+ (Enter keeps ...${AWS_SECRET_ACCESS_KEY: -4})}"
        secret="${ANSWER:-${AWS_SECRET_ACCESS_KEY:-}}"
        ANSWER=""
        [ -n "$secret" ] || { problem "S3 needs it"; continue; }
        "$FP" config check AWS_SECRET_ACCESS_KEY - <<<"$secret" >/dev/null 2>&1 && break
        problem "no spaces"
      done
    fi
    restic_open "$repo" "$password" "$key_id" "$secret"
    case "$RESTIC_STATE" in
      open) ;;
      wrong_password)
        problem "that repository has another password than the one this server has"
        while [ "$RESTIC_STATE" != open ]; do
          ask_secret "Its password (Enter to give up)"
          password="$ANSWER"
          ANSWER=""
          [ -n "$password" ] || break
          restic_open "$repo" "$password" "$key_id" "$secret"
          case "$RESTIC_STATE" in
            open) ;;
            wrong_password) problem "not that one either" ;;
            *) problem "restic cannot open it now: ${RESTIC_PROBLEM:-it says nothing is there}" ;;
          esac
        done
        if [ -z "$password" ]; then
          say "Nothing kept: scripts/firefly-pocket setup backups, any time."
          SKIPPED+=("offsite backups: scripts/firefly-pocket setup backups")
          return 0
        fi
        ;;
      missing)
        confirm "Nothing is there yet. Make a restic repository there?" y || continue
        if ! restic_make "$repo" "$password" "$key_id" "$secret"; then
          problem "restic init failed: $RESTIC_PROBLEM"
          continue
        fi
        made=1
        ;;
      *)
        problem "restic cannot open it: $RESTIC_PROBLEM"
        continue
        ;;
    esac
    { put RESTIC_REPOSITORY "$repo" && put RESTIC_PASSWORD "$password"; } \
      || die "the repository opens, but the settings store did not take it"
    if [ -n "$key_id" ]; then
      { put AWS_ACCESS_KEY_ID "$key_id" && put AWS_SECRET_ACCESS_KEY "$secret"; } \
        || die "the repository opens, but the settings store did not take its S3 keys"
    fi
    secret=""
    if [ -n "$made" ]; then
      ok "repository made"
      restic_password_note "$password"
    else
      ok "the repository opens: $RESTIC_SNAPSHOTS snapshots in it"
    fi
    password=""
    return 0
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

# ---------------------------------------------------------------- finish ---
# Setup web's code works until setup is finished: from then on the console has
# no say, until it signs in with Firefly III (Setup UI step 8). It is started
# again without it.
step_finish() {
  has SETUP_CODE || return 0
  has IMPORTER_FIREFLY_TOKEN || die "the account comes first: scripts/firefly-pocket setup account, or the console's"
  heading "Finish"
  drop SETUP_CODE
  reload
  "$FP" console status
  compose up -d --no-build --no-deps console
  ok "setup is finished: the console's setup code works no more"
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
    for step in domain you account start bank suggestions alerts backups start updates finish; do
      "step_$step"
    done
    summary
    ;;
  domain | you | account | bank | suggestions | alerts | backups)
    [ -f "$CONFIG" ] || [ "$1" = domain ] || die "nothing is set up yet: run scripts/firefly-pocket setup"
    "step_$1"
    [ "$1" = domain ] && [ ! -f "$COMPOSE_DIR/.env" ] || step_start
    ;;
  start | updates | finish)
    [ -f "$CONFIG" ] || die "nothing is set up yet: run scripts/firefly-pocket setup"
    "step_$1"
    ;;
  web)
    step_web
    ;;
  *)
    sed -n '3,49s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
    exit 2
    ;;
esac
