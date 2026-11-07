#!/usr/bin/env bash
#
# The server's half of the Firefly Pocket Console (Setup UI steps 4 to 8).
#
#     scripts/firefly-pocket console apply     apply what the console saved, then write its status
#     scripts/firefly-pocket console status    write its status only
#     scripts/firefly-pocket console install   the systemd units that run apply as soon as the
#                                              console saves something (uses sudo)
#     scripts/firefly-pocket console client    the "Sign in with Firefly III" clients of the
#                                              console and of Firefly Pocket, registered in
#                                              Firefly III (account.sh); with --if-missing,
#                                              only when one is not there yet, as the deploy
#                                              runs it
#     scripts/firefly-pocket console expire    revoke the console's Firefly III tokens older
#                                              than eight hours, as the crontab does hourly
#
# The console (services/console) runs in a container that holds no secret but
# the setup code, and after setup its owner's Firefly III token while they are
# signed in, and cannot reach Docker. It can add files to
# compose/console/inbox, which it cannot list, and read compose/console/status.
# This is the only thing that reads the one and writes the other:
#
#   inbox/<32 hex>.json  one request, carrying the setup code, so a file another user of
#                        this machine drops in does nothing. The code works until setup is
#                        finished: until the console's Finish, or the wizard's, removes it.
#                        From then on a request carries, in place of "code", the "token"
#                        Firefly III gave the console when its owner signed in (Setup UI
#                        step 8), and is applied only once Firefly III's API takes that
#                        token as SITE_OWNER's, and it is the console client's and less than
#                        eight hours old (_owner). After setup, the bank to updates requests
#                        below, and one more:
#       {"action": "signout", "token": "..."}
#                        the console's Sign out: Firefly III revokes that token
#                        Before Firefly III has its account (the importer's token, which
#                        opens the gate), two kinds:
#       {"action": "server", "code": "...", "settings": {"DOMAIN": "...", "SITE_OWNER": "...",
#        "LEGAL_OWNER_NAME": "...", "TZ": "..."}}
#                        those four settings and no other; each value is checked as config
#                        set checks it, and one bad value changes nothing. Then Caddy and
#                        the console start again with them, and nothing else: during setup
#                        nothing else runs yet
#       {"action": "account", "code": "...", "password": "..."}
#                        the setup wizard's account step with that password (account.sh):
#                        every image pulled, Postgres and Firefly III started, the account
#                        $SITE_OWNER and one token per app made inside Firefly III, then
#                        every service started, which opens the gate. Minutes; the request
#                        says how far it got as it goes
#                        and after it, these:
#       {"action": "bank_key", "code": "..."}
#                        the wizard's bank step, its first half (bank.sh): a new key for an
#                        Enable Banking application, kept in the store, and its certificate,
#                        which the status shows for the console to hand out. The application
#                        ID goes, as it was the old key's; the importer starts again
#       {"action": "bank", "code": "...", "app_id": "..."}
#                        its second half: kept, and the importer started again with it, once
#                        Enable Banking takes a request signed with the key for that ID
#       {"action": "suggestions", "code": "...", "provider": "anthropic" or "gemini",
#        "key": "...", "model": "..."}
#                        the wizard's suggestions step (suggestions.sh): the key and the
#                        model kept once the provider has that model for the key
#       {"action": "ntfy", "code": "...", "url": "..."}
#                        the wizard's alerts step, its ntfy half (alerts.sh): the topic kept
#                        once ntfy takes a test alert at it; an empty URL stops ntfy
#       {"action": "ntfy_test", "code": "..."}
#                        a test alert to the topic kept
#       {"action": "healthchecks", "code": "...", "key": "..."}
#                        its other half: healthchecks.io's two checks made with that API
#                        key, which is not kept, and their ping URLs kept
#       {"action": "backups", "code": "...", "repository": "...", "access_key_id": "...",
#        "secret_access_key": "...", "mode": "new" or "existing", "password": "..."}
#                        the wizard's backups step (backups.sh): a new repository made with
#                        the password the console showed you to keep, or one restic uses
#                        already opened with its password (empty: this server's). Empty S3
#                        keys keep the server's. All of it kept once the repository opens
#       {"action": "updates", "code": "..."}
#                        the wizard's updates step: the deploy agent turned on, with
#                        install-deploy-agent.sh for this checkout. Its timer is a systemd
#                        unit, so this needs sudo without a password, as a server made from
#                        terraform/cloud-init.yaml has; otherwise it is refused, and the
#                        wizard, which can ask for the password, does it
#       {"action": "finish", "code": "..."}
#                        the end of setup: the code is removed, and the console starts
#                        again without it
#   status/status.json   those settings, the five names, this server's addresses and
#                        timezone, whether Firefly III has its account and whether setup is
#                        finished, the bank step's certificate, application ID and redirect
#                        URLs, the last four characters of each key and topic kept, the
#                        model, whether the checks are made, the backup's repository (any
#                        password in it hidden) and whether restic is installed, whether the
#                        deploy agent is on and the repository it follows, the console's
#                        OAuth client ID (public), and what became of the last 20 requests.
#                        No secret.
#
# apply runs under the lock the deploy and the cron jobs take, one request after
# another in the order the console wrote them.

set -euo pipefail
shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/compose"
CONSOLE_DIR="$COMPOSE_DIR/console"
INBOX="$CONSOLE_DIR/inbox"
STATUS="$CONSOLE_DIR/status/status.json"
FP="$REPO_ROOT/scripts/firefly-pocket"
LOCK_FILE="${LOCK_FILE:-/run/lock/fireflyx.lock}"
# The settings a request may change, in the order its message names them.
ALLOWED=(DOMAIN SITE_OWNER LEGAL_OWNER_NAME TZ)
declare -A LABEL=([DOMAIN]="the domain" [SITE_OWNER]="your email" [LEGAL_OWNER_NAME]="your name" [TZ]="the timezone")

# shellcheck source=host.sh
source "$REPO_ROOT/scripts/host.sh"
# shellcheck source=bank.sh
source "$REPO_ROOT/scripts/bank.sh"
# shellcheck source=suggestions.sh
source "$REPO_ROOT/scripts/suggestions.sh"
# shellcheck source=alerts.sh
source "$REPO_ROOT/scripts/alerts.sh"
# shellcheck source=backups.sh
source "$REPO_ROOT/scripts/backups.sh"

# Compose takes a variable from its environment over compose/.env, and lib.sh
# exports every value .env has. So nothing that ran this (a shell that sourced
# lib.sh, the boot test) chooses what a service gets: compose/.env, as the
# store writes it, does. A step that sources lib.sh sources it again after it
# writes .env, before compose.
while IFS= read -r key; do unset "$key"; done < <(jq -r 'keys[]' "$REPO_ROOT/scripts/settings.json")

die() { echo "FATAL: $*" >&2; exit 1; }
# refuse: as die, for a request that changed nothing.
refuse() { echo "FATAL: $*" >&2; exit 2; }

# The directories the console's container mounts, and the one the importer
# mounts the bank step's certificate from (bank.sh). Made here, by this user,
# before compose starts either: Docker would make missing ones itself, owned by
# root. The deploy, setup web and the wizard's start step all write the status
# first. The inbox is like /tmp without the reading: the console, another user
# (docker-compose.yml), can add files but cannot list them or remove any.
console_dirs() {
  mkdir -p "$INBOX" "$CONSOLE_DIR/status" "$(dirname "$EB_CERT")"
  chmod 755 "$CONSOLE_DIR" "$CONSOLE_DIR/status"
  chmod 1733 "$INBOX"
}

# stored <KEY>: a plain setting as the store has it, empty when it has none.
stored() {
  [ -f "$COMPOSE_DIR/config.json" ] || return 0
  jq -r --arg k "$1" '.[$k] // empty' "$COMPOSE_DIR/config.json"
}

# env_value <KEY>: as compose/.env has it, without the key on any command line.
env_value() {
  [ -f "$COMPOSE_DIR/.env" ] || return 0
  sed -n "s/^$1=//p" "$COMPOSE_DIR/.env" | tail -n 1
}

# Firefly III has its account once the importer has its token: compose derives
# the gate from the same line of compose/.env (FIREFLY_POCKET_SETUP).
account_made() { [ -n "$(env_value IMPORTER_FIREFLY_TOKEN)" ]; }
# Setup is finished once Firefly III has its account and there is no setup
# code: the console's Finish and the wizard's remove it, and a server set up
# over SSH alone never had one.
setup_done() { account_made && [ -z "$(env_value SETUP_CODE)" ]; }

compose() { docker compose --project-directory "$COMPOSE_DIR" "$@"; }
ok() { printf '   ok: %s\n' "$*"; }

# --------------------------------------------------------------- status ---
RESULTS='{}'
ACTION=""   # the request's action, once it is known: the console words its outcome by it
# result <id> <running|applied|refused|failed> <message>
result() {
  RESULTS="$(jq -c --arg id "$1" --arg state "$2" --arg message "$3" --arg action "$ACTION" \
    --arg at "$(date -u +%FT%TZ)" '.[$id] = {state: $state, message: $message, action: $action, at: $at}' <<<"$RESULTS")"
  echo "request $1: $2: $3"
}

# The five names, and the redirect URLs Enable Banking needs, as lib.sh and
# bank.sh derive them from this compose/.env: console.sh _names. In a process of
# its own: lib.sh stops a script that has no .env, or a name and no domain.
names_json() {
  [ -f "$COMPOSE_DIR/.env" ] || { echo '{"names": [], "redirect_urls": []}'; return 0; }
  "$REPO_ROOT/scripts/console.sh" _names 2>/dev/null || echo '{"names": [], "redirect_urls": []}'
}

cmd_names() {
  local urls
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh" >/dev/null 2>&1
  mapfile -t urls < <(eb_redirect_urls)
  jq -nc --args '{
      names: ([["admin", "firefly", "app", "import", "legal"], $ARGS.positional[0:5]] | transpose
        | map({role: .[0], host: .[1]})),
      redirect_urls: $ARGS.positional[5:] }' \
    "$ADMIN_HOSTNAME" "$FIREFLY_HOSTNAME" "$NEXT_HOSTNAME" "$IMPORT_HOSTNAME" "$LEGAL_HOSTNAME" "${urls[@]}"
}

# The bank step's: whether there is a key, its certificate when this server made
# it (public: it is uploaded to Enable Banking), and the application ID.
bank_json() {
  local key cert="" has_key=false
  key="$(env_value ENABLE_BANKING_PRIVATE_KEY)"
  if [ -n "$key" ]; then
    has_key=true
    ! eb_cert_matches "$key" || cert="$(cat "$EB_CERT")"
  fi
  key=""
  jq -nc --argjson key "$has_key" --arg certificate "$cert" --arg app_id "$(env_value ENABLE_BANKING_APP_ID)" \
    '{key: $key, certificate: $certificate, app_id: $app_id}'
}

# last4 <KEY>: "…" and a secret's last four characters, as config get shows
# it; empty when it is not set.
last4() {
  local value
  value="$(env_value "$1")"
  [ -z "$value" ] || printf '…%s' "${value: -4}"
}

# The suggestions, alerts, backups and updates steps': what is kept, a secret
# only by its last four.
extras_json() {
  local checks=false restic=false repository agent=false
  [ -z "$(env_value HEALTHCHECK_NIGHTLY_URL)" ] || [ -z "$(env_value HEALTHCHECK_BACKUP_URL)" ] || checks=true
  ! command -v restic >/dev/null 2>&1 || restic=true
  repository="$(env_value RESTIC_REPOSITORY)"
  [ -z "$repository" ] || repository="$(restic_shown "$repository")"
  ! agent_on || agent=true
  jq -nc --arg anthropic "$(last4 ANTHROPIC_API_KEY)" --arg gemini "$(last4 GEMINI_API_KEY)" \
    --arg model "$(stored SUGGESTER_MODEL)" --arg default "$SUGGESTER_DEFAULT_MODEL" \
    --arg ntfy "$(last4 NTFY_URL)" --argjson checks "$checks" \
    --arg repository "$repository" --arg key_id "$(last4 AWS_ACCESS_KEY_ID)" \
    --arg secret_key "$(last4 AWS_SECRET_ACCESS_KEY)" --argjson restic "$restic" \
    --argjson agent "$agent" --arg origin "$(origin_shown)" '
    { suggestions: {anthropic: $anthropic, gemini: $gemini, model: (if $model == "" then $default else $model end)},
      alerts: {ntfy: $ntfy, healthchecks: $checks},
      backups: {repository: $repository, access_key_id: $key_id, secret_access_key: $secret_key, restic: $restic},
      updates: {agent: $agent, origin: $origin} }'
}

# origin_shown: the repository this checkout follows, as the console may show
# it: a token in its URL is not, as a password in a restic repository's is not.
origin_shown() {
  local origin
  origin="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  [ -z "$origin" ] || restic_shown "$origin"
}

write_status() {
  local old='{}' tmp account=false finished=false
  console_dirs
  if [ -f "$STATUS" ]; then
    old="$(jq -c '.requests // {} | objects' "$STATUS" 2>/dev/null || true)"
    [ -n "$old" ] || old='{}'
  fi
  ! account_made || account=true
  ! setup_done || finished=true
  tmp="$(mktemp "$CONSOLE_DIR/status/.status.XXXXXX")"
  jq -n --arg written "$(date -u +%FT%TZ)" --argjson account "$account" --argjson finished "$finished" \
        --arg domain "$(stored DOMAIN)" --arg owner "$(stored SITE_OWNER)" \
        --arg name "$(stored LEGAL_OWNER_NAME)" --arg tz "$(stored TZ)" --arg admin "$(stored ADMIN_HOSTNAME)" \
        --arg host_tz "$(host_timezone)" --arg v4 "$(my_address 4)" --arg v6 "$(my_address 6)" \
        --argjson derived "$(names_json)" --argjson bank "$(bank_json)" --argjson extras "$(extras_json)" \
        --arg client_id "$(stored CONSOLE_CLIENT_ID)" --argjson old "$old" --argjson new "$RESULTS" '
    { written: $written, account: $account, setup_done: $finished,
      settings: {DOMAIN: $domain, SITE_OWNER: $owner, LEGAL_OWNER_NAME: $name, TZ: $tz, ADMIN_HOSTNAME: $admin},
      host_timezone: $host_tz, addresses: {v4: $v4, v6: $v6}, names: $derived.names,
      bank: ($bank + {redirect_urls: $derived.redirect_urls}),
      suggestions: $extras.suggestions, alerts: $extras.alerts, backups: $extras.backups, updates: $extras.updates,
      signin: {client_id: $client_id},
      requests: ($old + $new | to_entries | sort_by(.value.at) | .[-20:] | from_entries) }' > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$STATUS"
}

# ---------------------------------------------------------------- apply ---
# follow <KEY> <old> <new>: a setting that follows another changes with it,
# unless it was set to something else on purpose (as setup's you step does).
follow() {
  local current
  current="$(stored "$1")"
  if [ -z "$current" ] || [ "$current" = "$2" ]; then
    "$FP" config set --no-render "$1" - <<<"$3" >/dev/null
  fi
}

# apply_one <id> <file>: 0 when Caddy and the console need starting again.
apply_one() {
  local id="$1" file="$2" code given token
  ACTION="$(jq -r 'if type == "object" and (.action | type) == "string" then .action else "" end' <"$file" 2>/dev/null || true)"
  case "$ACTION" in
    server | account | bank_key | bank | suggestions | ntfy | ntfy_test | healthchecks | backups | updates | finish | signout) ;;
    *)
      ACTION=""
      result "$id" refused "Not a request this version of the server knows."
      return 1
      ;;
  esac
  if setup_done; then
    # From here on, the console signed in with Firefly III, as its owner.
    case "$ACTION" in
      server | account | finish)
        result "$id" refused "Setup is finished, and that step with it. To change the domain or your details, on the server: scripts/firefly-pocket setup domain, or setup you"
        return 1
        ;;
    esac
    token="$(jq -r '.token | strings' <"$file" 2>/dev/null || true)"
    if [ -z "$token" ]; then
      result "$id" refused "Setup is finished, so the console changes something only once you sign in to it with Firefly III."
      return 1
    fi
    # A JWT: anything else goes nowhere near curl's or PHP's input.
    if [ "${#token}" -gt 8192 ] || [[ ! "$token" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
      result "$id" refused "Not a sign-in from this server's console."
      return 1
    fi
    if [ "$ACTION" = signout ]; then
      if child owner end <<<"$token"; then result "$id" applied "$MESSAGE"; else owner_refused "$id"; fi
      return 1
    fi
    if ! child owner check <<<"$token"; then
      owner_refused "$id"
      return 1
    fi
  else
    if [ "$ACTION" = signout ]; then
      result "$id" refused "Signing in with Firefly III starts once setup is finished."
      return 1
    fi
    # Compared here, not by jq: an argument would show the code to every user of this machine.
    code="$(env_value SETUP_CODE)"
    given="$(jq -r '.code | strings' <"$file" 2>/dev/null || true)"
    if [ -z "$code" ] || [ "$given" != "${code//-/}" ]; then
      result "$id" refused "Not this server's setup code: the request did not come from its console."
      return 1
    fi
  fi
  # The steps in their order: the Server step and the account until the
  # account exists, the bank step and Finish after.
  if account_made; then
    case "$ACTION" in
      server)
        result "$id" refused "Firefly III has its account, so the Server step is done. To change it, on the server: scripts/firefly-pocket setup domain, or setup you"
        return 1
        ;;
      account)
        result "$id" refused "Firefly III has its account already."
        return 1
        ;;
    esac
  elif [ "$ACTION" != server ] && [ "$ACTION" != account ]; then
    result "$id" refused "Make the Firefly III account first."
    return 1
  fi
  "apply_$ACTION" "$id" "$file"
}

# owner_refused <id>: what child owner said, as the request's outcome: refused
# when it said no (exit 2), failed when it could not tell.
owner_refused() {
  if [ "$CHILD_RC" -eq 2 ]; then
    result "$1" refused "$MESSAGE"
  else
    result "$1" failed "${MESSAGE:-The server could not ask Firefly III about your sign-in; the journal has why (journalctl -u firefly-pocket-console)}"
  fi
}

# child <name> [args...]: console.sh _<name> in a process of its own, so that
# set -e stops it at the first failure; stdin goes to it. What it says goes to
# the journal as it says it, and MESSAGE is its last "FATAL: " line, or else its
# last "DONE: " line.
child() {
  local log rc=0
  log="$(mktemp)"
  "$REPO_ROOT/scripts/console.sh" "_$1" "${@:2}" 2>&1 | tee "$log" >&2 || rc=$?
  MESSAGE="$(sed -n 's/^FATAL: //p' "$log" | tail -n 1)"
  [ "$rc" -ne 0 ] || MESSAGE="$(sed -n 's/^DONE: //p' "$log" | tail -n 1)"
  rm -f "$log"
  CHILD_RC="$rc"
  return "$rc"
}
CHILD_RC=0

# apply_server <id> <file>: 0 when it changed a setting.
apply_server() {
  local id="$1" file="$2" settings key value out problems=() changed=() old_owner
  # Only the shape the console writes: every value a string with no control
  # character, only the allowed settings, all four of them.
  settings="$(jq -ce --args '
      select((.settings | type) == "object") | .settings
      | select(all(.[]; type == "string" and (explode | all(. >= 32 and . != 127))))
      | select(keys == ($ARGS.positional | sort))' "${ALLOWED[@]}" <"$file" 2>/dev/null)" \
    || { result "$id" refused "Not a request this version of the server knows."; return 1; }

  for key in "${ALLOWED[@]}"; do
    value="$(jq -r --arg k "$key" '.[$k]' <<<"$settings")"
    if [ -z "$value" ]; then
      [ "$key" = LEGAL_OWNER_NAME ] || problems+=("${LABEL[$key]^} is needed.")
      continue
    fi
    out="$("$FP" config check "$key" - 2>&1 <<<"$value")" || problems+=("$out")
  done
  if [ "${#problems[@]}" -gt 0 ]; then
    result "$id" refused "${problems[*]}"
    return 1
  fi

  old_owner="$(stored SITE_OWNER)"
  for key in "${ALLOWED[@]}"; do
    value="$(jq -r --arg k "$key" '.[$k]' <<<"$settings")"
    [ "$value" != "$(stored "$key")" ] || continue
    if [ -z "$value" ]; then
      out="$("$FP" config unset "$key" 2>&1)" || { result "$id" failed "$out"; return 1; }
    else
      out="$("$FP" config set --no-render "$key" - 2>&1 <<<"$value")" || { result "$id" failed "$out"; return 1; }
    fi
    changed+=("${LABEL[$key]}")
    if [ "$key" = SITE_OWNER ]; then
      follow ACME_EMAIL "$old_owner" "$value"
      follow VAPID_SUBJECT "mailto:$old_owner" "mailto:$value"
    fi
  done
  if [ "${#changed[@]}" -eq 0 ]; then
    result "$id" applied "Nothing to change: the server has these values already."
    return 1
  fi
  out="$("$FP" config render 2>&1)" || { result "$id" failed "$out"; return 1; }
  local list="${changed[0]}"
  [ "${#changed[@]}" -lt 2 ] || list="$(printf '%s, ' "${changed[@]:0:${#changed[@]}-1}")"
  [ "${#changed[@]}" -lt 2 ] || list="${list%, } and ${changed[-1]}"
  result "$id" applied "Saved: $list."
  return 0
}

# apply_account <id> <file>: 1, always: what it starts, it starts itself.
apply_account() {
  local id="$1" file="$2" password length message rc=0
  # Only the shape the console writes: a password with no control character.
  password="$(jq -er '.password | strings | select(explode | all(. >= 32 and . != 127))' <"$file" 2>/dev/null)" \
    || { result "$id" refused "Not a request this version of the server knows."; return 1; }
  length="$(jq -r '.password | length' <"$file")"
  if [ "$length" -lt 16 ]; then
    result "$id" refused "The password needs at least 16 characters, Firefly III's minimum."
    return 1
  fi
  if [ -z "$(stored SITE_OWNER)" ] || [ -z "$(stored TZ)" ]; then
    result "$id" refused "Save the Server step first: the account's email is the one it keeps."
    return 1
  fi
  result "$id" running "Starting."
  write_status
  # On stdin, as the wizard takes it: never on a command line or in the environment.
  child account "$id" < <(printf '%s' "$password") || rc=$?
  password=""
  message="${MESSAGE:-It stopped; journalctl -u firefly-pocket-console says where.}"
  message="${message%.}."
  if [ "$rc" -eq 0 ]; then
    result "$id" applied "Your Firefly III account is ready, and every service runs."
  elif account_made; then
    result "$id" failed "$message The account and the tokens are made. To start the rest, on the server: scripts/firefly-pocket setup start"
  else
    result "$id" failed "$message Nothing is public yet. Try again, or on the server: scripts/firefly-pocket setup account"
  fi
  return 1
}

# apply_bank_key <id> <file>, apply_bank <id> <file>: 1, always: the importer
# is the only one to start again, and console.sh _bank_key and _bank start it.
apply_bank_key() {
  local id="$1" rc=0
  result "$id" running "Making the key."
  write_status
  child bank_key || rc=$?
  bank_result "$id" "$rc" "A new key, and its certificate to upload with your application. The private key stays on this server."
  return 1
}

apply_bank() {
  local id="$1" file="$2" app_id rc=0
  # Only the shape the console writes, and an ID as config set takes it.
  app_id="$(jq -r '.app_id | strings' <"$file" 2>/dev/null || true)"
  if [ -z "$app_id" ] || [[ "$app_id" == *[[:cntrl:]]* ]] \
    || ! "$FP" config check ENABLE_BANKING_APP_ID - <<<"$app_id" >/dev/null 2>&1; then
    result "$id" refused "Not an application ID: one looks like 1b4e28ba-2fa1-11d2-883f-0016d3cca427."
    return 1
  fi
  result "$id" running "Asking Enable Banking about the application."
  write_status
  child bank "$app_id" || rc=$?
  bank_result "$id" "$rc" "Saved."
  return 1
}

# bank_result <id> <rc> <what it did>: exit 2 changed nothing; any other, part of it.
bank_result() {
  if [ "$2" -eq 0 ]; then
    result "$1" applied "${MESSAGE:-$3}"
  elif [ "$2" -eq 2 ]; then
    result "$1" refused "${MESSAGE:-It changed nothing; journalctl -u firefly-pocket-console says why.}"
  else
    result "$1" failed "${MESSAGE:-It stopped; journalctl -u firefly-pocket-console says where.}"
  fi
}

# strings_of <file> <field>: a request's string field, empty when it is no
# string or has a control character. Only the shape the console writes.
string_of() {
  jq -r --arg f "$2" '.[$f] | strings | select(explode | all(. >= 32 and . != 127))' <"$1" 2>/dev/null || true
}

# A secret into the store, on stdin; config set checks it again.
keep() { "$FP" config set --no-render "$1" - <<<"$2" >/dev/null 2>&1; }

# apply_suggestions, apply_ntfy, apply_ntfy_test, apply_healthchecks <id> <file>:
# 1, always. Nothing to start again: the suggester and the jobs that alert run
# from cron, and read compose/.env when they do.
apply_suggestions() {
  local id="$1" file="$2" provider key model out
  provider="$(string_of "$file" provider)"
  key="$(string_of "$file" key)"
  model="$(string_of "$file" model)"
  case "$provider" in
    anthropic) model="${model:-$SUGGESTER_DEFAULT_MODEL}"; [[ "$model" == claude-* ]] || provider="" ;;
    gemini) [[ "$model" == gemini-* ]] || provider="" ;;
    *) provider="" ;;
  esac
  if [ -z "$provider" ] || [ -z "$key" ]; then
    result "$id" refused "Not a request this version of the server knows."
    return 1
  fi
  if ! out="$("$FP" config check ANTHROPIC_API_KEY - 2>&1 <<<"$key")"; then
    result "$id" refused "Not an API key: ${out#*: }."
    return 1
  fi
  if ! out="$("$FP" config check SUGGESTER_MODEL - 2>&1 <<<"$model")"; then
    result "$id" refused "Not a model name: ${out#*: }."
    return 1
  fi
  result "$id" running "Asking $provider for $model with this key."
  write_status
  if ! model_check "$provider" "$key" "$model"; then
    result "$id" refused "$MODEL_PROBLEM"
    return 1
  fi
  out=""
  if ! { keep "${provider^^}_API_KEY" "$key" && "$FP" config set --no-render SUGGESTER_MODEL - <<<"$model" >/dev/null 2>&1 \
         && out="$("$FP" config render 2>&1)"; }; then
    result "$id" failed "The key passed its check, but the settings store did not take it: ${out:-config set failed}"
    return 1
  fi
  key=""
  result "$id" applied "Saved: $provider has $model for this key. The suggester uses it from its next run, at night."
  return 1
}

apply_ntfy() {
  local id="$1" file="$2" url out
  url="$(string_of "$file" url)"
  if [ -z "$url" ]; then
    if jq -e '.url == ""' <"$file" >/dev/null 2>&1; then
      out="$("$FP" config unset NTFY_URL 2>&1)" || { result "$id" failed "${out#FATAL: }"; return 1; }
      result "$id" applied "No ntfy: alerts reach only the Firefly Pocket app."
    else
      result "$id" refused "Not a request this version of the server knows."
    fi
    return 1
  fi
  if ! out="$("$FP" config check NTFY_URL - 2>&1 <<<"$url")"; then
    result "$id" refused "Not a topic URL: ${out#*: }."
    return 1
  fi
  result "$id" running "Sending a test alert to the topic."
  write_status
  if ! ntfy_send "$url" "Firefly Pocket: test" "Alerts from $(hostname) arrive here."; then
    result "$id" refused "ntfy did not take a test alert at that URL, so it is not kept. Is it right, and is ntfy.sh up?"
    return 1
  fi
  out=""
  if ! { keep NTFY_URL "$url" && out="$("$FP" config render 2>&1)"; }; then
    result "$id" failed "ntfy took the test, but the settings store did not take the URL: ${out:-config set failed}"
    return 1
  fi
  result "$id" applied "Saved, and a test alert sent: it should be on your phone now. If it is not, subscribe to the topic in the ntfy app first, then send another test."
  return 1
}

apply_ntfy_test() {
  local id="$1" url
  url="$(env_value NTFY_URL)"
  if [ -z "$url" ]; then
    result "$id" refused "No ntfy topic is kept yet."
  elif ntfy_send "$url" "Firefly Pocket: test" "Alerts from $(hostname) arrive here."; then
    result "$id" applied "A test alert went out: it should be on your phone now."
  else
    result "$id" failed "ntfy did not take the test alert. Is ntfy.sh up?"
  fi
  return 1
}

apply_healthchecks() {
  local id="$1" file="$2" key out url tz
  key="$(string_of "$file" key)"
  if ! [[ "$key" =~ ^[A-Za-z0-9._-]{16,}$ ]]; then
    result "$id" refused "Not an API key: healthchecks.io's are 32 letters and digits, under the project's Settings, API Access."
    return 1
  fi
  tz="$(stored TZ)"
  result "$id" running "Making the two checks on healthchecks.io."
  write_status
  if ! TZ="${tz:-Etc/UTC}" hc_setup "$key"; then
    result "$id" refused "$HC_PROBLEM"
    return 1
  fi
  key=""
  out=""
  if ! { keep HEALTHCHECK_NIGHTLY_URL "$HC_NIGHTLY" && keep HEALTHCHECK_BACKUP_URL "$HC_BACKUP" \
         && out="$("$FP" config render 2>&1)"; }; then
    result "$id" failed "healthchecks.io made the checks, but the settings store did not take their ping URLs: ${out:-config set failed}"
    return 1
  fi
  for url in "$HC_NIGHTLY" "$HC_BACKUP"; do
    hc_ping "$url" "set up by the Firefly Pocket Console" || true
  done
  result "$id" applied "Both checks are made on healthchecks.io, the nightly import's and the backup's, with their schedules in ${tz:-Etc/UTC}. It mails you when either does not report in on time. The API key is not kept."
  return 1
}

# apply_backups <id> <file>: 1, always: nothing to start again; the nightly
# backup reads compose/.env when it runs. Runs restic itself: the agent's user
# is the one the nightly backup runs as.
# shellcheck disable=SC1111  # typographic quotes, in what the console shows
apply_backups() {
  local id="$1" file="$2" repository key_id secret mode password out
  repository="$(string_of "$file" repository)"
  key_id="$(string_of "$file" access_key_id)"
  secret="$(string_of "$file" secret_access_key)"
  mode="$(string_of "$file" mode)"
  password="$(string_of "$file" password)"
  # Only the shape the console writes; a new repository's password is one it made.
  if [ -z "$repository" ] || { [ "$mode" != new ] && [ "$mode" != existing ]; } \
    || { [ "$mode" = new ] && [ "${#password}" -lt 16 ]; }; then
    result "$id" refused "Not a request this version of the server knows."
    return 1
  fi
  if ! out="$("$FP" config check RESTIC_REPOSITORY - 2>&1 <<<"$repository")"; then
    result "$id" refused "Not a repository: ${out#*: }."
    return 1
  fi
  if ! command -v restic >/dev/null 2>&1; then
    result "$id" refused "restic is not installed on this server. On the server: sudo apt-get install -y restic, then save this again."
    return 1
  fi
  if [[ "$repository" == s3:* ]]; then
    key_id="${key_id:-$(env_value AWS_ACCESS_KEY_ID)}"
    secret="${secret:-$(env_value AWS_SECRET_ACCESS_KEY)}"
    if [ -z "$key_id" ] || [ -z "$secret" ]; then
      result "$id" refused "S3 storage needs its access key ID and secret access key."
      return 1
    fi
    if ! "$FP" config check AWS_ACCESS_KEY_ID - <<<"$key_id" >/dev/null 2>&1 \
      || ! "$FP" config check AWS_SECRET_ACCESS_KEY - <<<"$secret" >/dev/null 2>&1; then
      result "$id" refused "Not an S3 key: no spaces in either."
      return 1
    fi
  else
    key_id="" secret=""
  fi
  password="${password:-$(env_value RESTIC_PASSWORD)}"
  if [ -z "$password" ]; then
    result "$id" refused "The repository's password is needed."
    return 1
  fi
  result "$id" running "Opening the repository."
  write_status
  restic_open "$repository" "$password" "$key_id" "$secret"
  case "$RESTIC_STATE:$mode" in
    open:*) out="Saved: the repository opens, with $RESTIC_SNAPSHOTS snapshots in it." ;;
    wrong_password:new)
      result "$id" refused "A restic repository is there already, with another password. To back up to it, choose “One restic uses already” and give its password."
      return 1
      ;;
    wrong_password:existing)
      result "$id" refused "That is not the repository's password: restic says “wrong password or no key found”."
      return 1
      ;;
    missing:existing)
      result "$id" refused "Nothing is there yet. To make a repository there, choose “A new repository”."
      return 1
      ;;
    missing:new)
      result "$id" running "Making the repository."
      write_status
      if ! restic_make "$repository" "$password" "$key_id" "$secret"; then
        result "$id" refused "restic could not make it: $RESTIC_PROBLEM"
        return 1
      fi
      out="Saved: restic made the repository, with the password you kept."
      ;;
    *)
      result "$id" refused "restic cannot open it: $RESTIC_PROBLEM"
      return 1
      ;;
  esac
  local message="$out"
  out=""
  if ! { "$FP" config set --no-render RESTIC_REPOSITORY - <<<"$repository" >/dev/null 2>&1 \
         && keep RESTIC_PASSWORD "$password" \
         && { [ -z "$key_id" ] || { keep AWS_ACCESS_KEY_ID "$key_id" && keep AWS_SECRET_ACCESS_KEY "$secret"; }; } \
         && out="$("$FP" config render 2>&1)"; }; then
    result "$id" failed "The repository opens, but the settings store did not take it: ${out:-config set failed}"
    return 1
  fi
  password="" secret=""
  result "$id" applied "$message The nightly backup, at 02:00, copies to it from its next run."
  return 1
}

# apply_updates <id> <file>: 1, always: what the deploy agent starts, its first
# run starts, within two minutes; it waits for this lock.
apply_updates() {
  local id="$1" out key
  if agent_on; then
    result "$id" applied "The deploy agent is on already."
    return 1
  fi
  # sudo -n: never a prompt, which nobody would answer.
  if ! sudo -n true 2>/dev/null; then
    result "$id" refused "The deploy agent's timer is a systemd unit, so turning it on needs sudo, and this server's user has no sudo without a password. On the server: scripts/firefly-pocket setup updates, which asks for it."
    return 1
  fi
  result "$id" running "Turning on the deploy agent."
  write_status
  out="$(REPO_DIR="$REPO_ROOT" "$REPO_ROOT/scripts/install-deploy-agent.sh" </dev/null 2>&1)" || {
    printf '%s\n' "$out" >&2
    result "$id" failed "The deploy agent did not turn on: $(grep -v '^[[:space:]]*$' <<<"$out" | tail -n 1 | cut -c1-300)"
    return 1
  }
  printf '%s\n' "$out" >&2
  # A private fork is fetched with a deploy key, which the installer makes and
  # stops at: it is public, and the console shows it.
  if grep -q 'Created a deploy key' <<<"$out"; then
    key="$(grep -m 1 '^ssh-ed25519 ' <<<"$out" || true)"
    result "$id" refused "This server fetches a private repository, so it needs a deploy key. Add this one to the repository under Settings, Deploy keys, without write access, then turn the agent on again: $key"
    return 1
  fi
  if ! agent_on; then
    result "$id" failed "The installer ran, but fireflyx-deploy.timer is not on. On the server: systemctl status fireflyx-deploy.timer"
    return 1
  fi
  result "$id" applied "The deploy agent is on. Within two minutes it deploys master of $(origin_shown) and installs the nightly jobs: the backup at 02:00, the bank import at 03:00 and the restore tests on Sundays."
  return 1
}

# apply_finish <id> <file>: 1, always: it starts the console again itself.
apply_finish() {
  local id="$1" out
  out="$("$FP" config unset SETUP_CODE 2>&1)" || { result "$id" failed "${out#FATAL: }"; return 1; }
  result "$id" applied "Setup is finished: the setup code works no more."
  write_status
  # Without the code, the console only says where things are.
  if ! out="$(compose up -d --no-build --no-deps console 2>&1)"; then
    printf '%s\n' "$out" >&2
    result "$id" failed "The setup code is gone, but the console did not start again without it. On the server: docker compose --project-directory compose logs console"
  fi
  return 1
}

# console.sh _account <id>, the password on stdin: apply_account's work, in a
# process of its own, so that set -e stops it at the first failure. What it does
# goes to the journal, and how far it got into the request, for the console.
cmd_account() {
  local id="$1" password="" out
  IFS= read -r password || [ -n "$password" ] || die "no password on stdin"
  ACTION=account
  progress() { result "$id" running "$1"; write_status; }
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"
  # shellcheck source=account.sh
  source "$REPO_ROOT/scripts/account.sh"
  # Anything this version generates that setup web did not. Not for the
  # journal: what it prints can hold the importer's password.
  FROM_SETUP=1 "$REPO_ROOT/scripts/gen-secrets.sh" >/dev/null
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"

  # Before the account: a download that fails then leaves nothing half done.
  progress "Downloading every service. The first time takes a few minutes."
  compose pull --quiet --ignore-buildable || die "Not every image downloaded; the journal has why (journalctl -u firefly-pocket-console)"
  progress "Starting Firefly III, and nothing that makes it public. Its first start sets up its database: a minute or two."
  firefly_up
  if [ "$USERS" = 0 ]; then
    progress "Making your account, $SITE_OWNER, and a token for each app."
  else
    progress "Firefly III has its account already, so its password stays as it was. Making a token for each app."
  fi
  make_tokens "$password"
  password=""
  progress "Starting every service. Once Caddy has started again, every name is open."
  compose up -d --no-build --remove-orphans || die "Not every service started; the journal has why (journalctl -u firefly-pocket-console)"
  out="$(smoke_test)" || die "${out^}"
  ok "$out"
}

# console.sh _bank_key: apply_bank_key's work, in a process of its own.
cmd_bank_key() {
  local dir
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"
  dir="$(mktemp -d)"
  # shellcheck disable=SC2064  # $dir is fixed now
  trap "rm -rf '$dir'" EXIT
  make_eb_key "$dir" || refuse "$EB_PROBLEM"
  "$FP" config render >/dev/null
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"
  # The importer has the old key: it starts again with the new one, and no ID.
  compose up -d --no-build importer \
    || die "The key is made, but the importer did not start again with it; the journal has why (journalctl -u firefly-pocket-console)"
  echo "DONE: A new key, and its certificate to upload with your application. The private key stays on this server."
}

# console.sh _bank <application ID>: apply_bank's work, in a process of its own.
cmd_bank() {
  local id="$1" notes
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"
  [ -n "${ENABLE_BANKING_PRIVATE_KEY:-}" ] || refuse "This server has no key yet: make one first."
  eb_check "$ENABLE_BANKING_PRIVATE_KEY" "$id" || refuse "$(eb_refusal)"
  echo "Enable Banking accepts a request signed with this server's key for $id: $(eb_about)"
  "$FP" config set --no-render ENABLE_BANKING_APP_ID - <<<"$id" >/dev/null
  "$FP" config render >/dev/null
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"
  compose up -d --no-build importer \
    || die "The ID is saved, but the importer did not start again with it; the journal has why (journalctl -u firefly-pocket-console)"
  notes="$(eb_notes | paste -sd' ' -)"
  echo "DONE: Saved: Enable Banking accepts a request signed with this server's key for $(eb_about). ${notes:+$notes }Link a bank from Firefly Pocket: Bank connections."
}

# console.sh client [--if-missing]: the console's sign-in client (account.sh),
# once Firefly III has its account; then the status, which carries its ID.
cmd_client() {
  account_made || die "Firefly III has no account yet: the account step registers the clients"
  if [ "${1:-}" = --if-missing ] && [ -n "$(stored CONSOLE_CLIENT_ID)" ] && [ -n "$(stored POCKET_CLIENT_ID)" ]; then
    return 0
  fi
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"
  # shellcheck source=account.sh
  source "$REPO_ROOT/scripts/account.sh"
  console_client
  pocket_client
  # Pocket reads its client from compose: start it again with the new one.
  if [ "$CLIENT_CHANGED" = 1 ]; then
    compose up -d --no-build next >/dev/null
    ok "Firefly Pocket started again with its client"
  fi
  write_status
}

# console.sh _owner <check|end>, the token on stdin: whether a request after
# setup comes from the console signed in as Firefly III's owner. check: the API
# takes the token, it is SITE_OWNER's, and it is the console client's, from the
# last eight hours; refused (exit 2) otherwise. end: that token revoked, as the
# console's Sign out asks. Either way the client's older tokens are revoked.
cmd_owner() {
  local token="" email answer said
  IFS= read -r token || [ -n "$token" ] || refuse "Not a sign-in from this server's console."
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"
  # shellcheck source=account.sh
  source "$REPO_ROOT/scripts/account.sh"
  [ -n "${CONSOLE_CLIENT_ID:-}" ] \
    || refuse "The console has no sign-in client on this server. On the server: scripts/firefly-pocket console client"
  if [ "$1" = end ]; then
    answer="$(console_tokens "$token" true)"
    token=""
    said="$(jq -r '.console_tokens.token' <<<"$answer")"
    case "$said" in
      ended | old | revoked) echo "DONE: Signed out: Firefly III takes the console's token no more." ;;
      *) refuse "Not a sign-in from this server's console." ;;
    esac
    return 0
  fi
  local rc=0
  email="$(token_user "$token")" || rc=$?
  case "$rc" in
    0) ;;
    1) refuse "Firefly III no longer takes this sign-in: sign out of the console, and in again." ;;
    *) die "Firefly III did not answer, so the server could not check your sign-in. Try again in a minute." ;;
  esac
  if [ -z "$email" ] || [ "${email,,}" != "${SITE_OWNER,,}" ]; then
    refuse "Signed in to Firefly III as ${email:-someone it did not name}, and the console is only for $SITE_OWNER."
  fi
  answer="$(console_tokens "$token")"
  token=""
  said="$(jq -r '.console_tokens.token' <<<"$answer")"
  case "$said" in
    current) echo "DONE: Signed in with Firefly III as $email." ;;
    old) refuse "That sign-in is more than eight hours old, and Firefly III takes it no more: sign out of the console, and in again." ;;
    revoked) refuse "That sign-in has ended: sign out of the console, and in again." ;;
    *) refuse "Not a sign-in from this server's console: another app's token for your account." ;;
  esac
}

# console.sh expire: the console's tokens older than its session revoked, as
# the crontab does every hour. Nothing to do before the client exists.
cmd_expire() {
  local answer
  if ! account_made || [ -z "$(stored CONSOLE_CLIENT_ID)" ]; then return 0; fi
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"
  # shellcheck source=account.sh
  source "$REPO_ROOT/scripts/account.sh"
  answer="$(console_tokens)"
  ok "the console's sign-ins older than eight hours: $(jq -r '.console_tokens.expired' <<<"$answer") revoked"
}

cmd_apply() {
  console_dirs
  exec 9>"$LOCK_FILE"
  flock -w 600 9 || die "still locked after ten minutes: a deploy, a backup or the nightly import holds it"
  local work f name id out applied=()
  work="$(mktemp -d "$CONSOLE_DIR/.apply.XXXXXX")"
  # shellcheck disable=SC2064  # $work is fixed now
  trap "rm -rf '$work'" EXIT
  # Out of the console's reach first: a link moves as a link, and nothing can
  # be swapped in under one once it is here.
  for f in "$INBOX"/*.json; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    mv -f -- "$f" "$work/" 2>/dev/null || true
  done
  # In the order the console wrote them: an account made before the Server
  # step it follows would refuse that step.
  while read -r _ name; do
    id="${name%.json}"
    [[ "$id" =~ ^[0-9a-f]{32}$ ]] || continue   # not one the console wrote: dropped
    if [ -L "$work/$name" ] || [ ! -f "$work/$name" ] || [ "$(stat -c %s "$work/$name")" -gt 65536 ]; then
      ACTION=""
      result "$id" refused "Not a request the console writes."
      continue
    fi
    if apply_one "$id" "$work/$name"; then applied+=("$id"); fi
  done < <(find "$work" -mindepth 1 -maxdepth 1 -name '*.json' -printf '%T@ %f\n' | sort -n)
  # A write the console never finished: it writes .<id>.tmp, then renames it.
  find "$INBOX" -maxdepth 1 -name '.*.tmp' -type f -mmin +60 -delete 2>/dev/null || true
  if [ "${#applied[@]}" -gt 0 ]; then
    if ! out="$(compose up -d --no-build --no-deps caddy console 2>&1)"; then
      printf '%s\n' "$out" >&2
      ACTION=server
      for id in "${applied[@]}"; do
        result "$id" failed "Saved, but Caddy did not start again with it. On the server: docker compose --project-directory compose logs caddy"
      done
    fi
  fi
  write_status
}

# -------------------------------------------------------------- install ---
cmd_install() {
  console_dirs
  local user
  user="$(id -un)"
  sudo tee /etc/systemd/system/firefly-pocket-console.service >/dev/null <<EOF
[Unit]
Description=firefly-pocket-stack: apply what the console saved (scripts/firefly-pocket console apply)
After=docker.service

[Service]
Type=oneshot
User=$user
WorkingDirectory=$REPO_ROOT
ExecStart=$REPO_ROOT/scripts/firefly-pocket console apply
TimeoutStartSec=30min
EOF
  # *.json only: the console writes .<id>.tmp first, so a half-written request
  # starts nothing, and one it never finished cannot start apply over and over.
  sudo tee /etc/systemd/system/firefly-pocket-console.path >/dev/null <<EOF
[Unit]
Description=firefly-pocket-stack: what the console saves (compose/console/inbox)

[Path]
PathExistsGlob=$INBOX/*.json

[Install]
WantedBy=paths.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now firefly-pocket-console.path
  echo "==> firefly-pocket-console.path is on: what the console saves is applied at once. Its log: journalctl -u firefly-pocket-console"
}

case "${1:-}" in
  apply) cmd_apply ;;
  status) write_status ;;
  install) cmd_install ;;
  client) cmd_client "${2:-}" ;;
  expire) cmd_expire ;;
  _owner) cmd_owner "${2:?}" ;;
  _account) cmd_account "${2:?}" ;;
  _bank_key) cmd_bank_key ;;
  _bank) cmd_bank "${2:?}" ;;
  _names) cmd_names ;;
  *)
    sed -n '3,16s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
    exit 2
    ;;
esac
