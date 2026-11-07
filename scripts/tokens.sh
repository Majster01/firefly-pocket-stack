#!/usr/bin/env bash
#
# The apps' Firefly III tokens (Setup UI step 10). Firefly III gives each one a
# year, so each night, first thing, the nightly run (nightly.sh) makes a new one
# for any app whose token has 30 days or less left, or which Firefly III no
# longer takes, and starts that app again with it, before the import needs it.
# Minting a name again revokes its old token (scripts/firefly-bootstrap.php).
#
#     scripts/firefly-pocket tokens                   each token, and the days it has left
#     scripts/firefly-pocket tokens rotate            what the nightly run does
#     scripts/firefly-pocket tokens rotate --days N   the same, for N days or less left
#
# The days left come from the token itself, its "exp" claim, as Firefly III
# checks it; the token goes to jq on stdin, never on a command line.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/compose"
FP="$REPO_ROOT/scripts/firefly-pocket"
DAYS=30

die() { echo "FATAL: $*" >&2; exit 1; }
ok() { printf '   ok: %s\n' "$*"; }
compose() { docker compose --project-directory "$COMPOSE_DIR" "$@"; }

# token_days_left <token>: whole days until it expires, from its exp claim (a
# negative number once it has). Fails when the token has no readable exp.
token_days_left() {
  local exp
  exp="$(jq -Rr 'split(".")[1] // "" | gsub("-"; "+") | gsub("_"; "/")
      | (if length % 4 == 0 then . else . + ("=" * (4 - length % 4)) end)
      | @base64d | fromjson | .exp // empty' <<<"$1" 2>/dev/null)" || return 1
  [[ "$exp" =~ ^[0-9]+$ ]] || return 1
  echo $(((exp - $(date +%s)) / 86400))
}

# token_due <token> <days>: whether the token needs a new one: it expires
# within <days>, or its expiry cannot be read.
token_due() {
  local left
  left="$(token_days_left "$1")" || return 0
  [ "$left" -le "$2" ]
}

cmd_status() {
  local entry key name left
  for entry in "${TOKENS[@]}"; do
    key="${entry%%:*}"
    name="${entry#*:}"
    if [ -z "${!key:-}" ]; then
      echo "$key (\"$name\"): none"
    elif left="$(token_days_left "${!key}")"; then
      echo "$key (\"$name\"): $left days left"
    else
      echo "$key (\"$name\"): its expiry cannot be read"
    fi
  done
}

# cmd_rotate [days]: a new token for each app whose token is due or which
# Firefly III no longer takes, kept in the store; then compose/.env written
# again and every service whose token changed started again with it.
cmd_rotate() {
  local days="$1" entry key name left mint=() keys=() request answer token
  for entry in "${TOKENS[@]}"; do
    key="${entry%%:*}"
    name="${entry#*:}"
    if [ -z "${!key:-}" ]; then
      die "$key is not set: this server has no Firefly III account yet (scripts/firefly-pocket setup account)"
    elif token_due "${!key}" "$days"; then
      left="$(token_days_left "${!key}" || echo "unknown")"
      echo "$key: $left days left, $days or less: a new one"
    elif ! token_works "${!key}"; then
      echo "$key: Firefly III no longer takes it: a new one"
    else
      ok "$key: $(token_days_left "${!key}") days left"
      continue
    fi
    mint+=("$name")
    keys+=("$key")
  done
  [ "${#mint[@]}" -gt 0 ] || return 0
  request="$(jq -nc --arg email "$SITE_OWNER" '{email: $email, tokens: $ARGS.positional}' --args "${mint[@]}")"
  answer="$(bootstrap <<<"$request")"
  for entry in "${TOKENS[@]}"; do
    key="${entry%%:*}"
    name="${entry#*:}"
    token="$(jq -r --arg n "$name" '.tokens[$n].token // empty' <<<"$answer")"
    [ -n "$token" ] || continue
    "$FP" config set --no-render "$key" - <<<"$token" >/dev/null 2>&1 \
      || die "Firefly III made a token for $name that $key does not take; its old token is revoked, so on the server: scripts/firefly-pocket setup account"
    ok "$key: a new token, \"$name\" in Firefly III, valid until $(jq -r --arg n "$name" '.tokens[$n].expires_at' <<<"$answer" | cut -c1-10)"
  done
  token=""
  answer=""
  "$FP" config render >/dev/null
  # shellcheck source=lib.sh
  source "$REPO_ROOT/scripts/lib.sh"
  for key in "${keys[@]}"; do
    token_works "${!key:-}" || die "Firefly III does not take the new $key"
  done
  # As the deploy starts what changed: the apps given a new token, and nothing
  # else. The suggester runs as a job, and reads its token when it runs.
  compose up -d --no-build --quiet-pull
  # What comes next calls them: the nightly import the importer, its alerts
  # Firefly Pocket. Each must answer first.
  if [[ " ${keys[*]} " == *" IMPORTER_FIREFLY_TOKEN "* ]]; then
    wait_for http://importer:8080/health "The importer" importer
  fi
  if [[ " ${keys[*]} " == *" NEXT_WARMUP_FIREFLY_TOKEN "* ]]; then
    wait_for http://next:80/api/test "Firefly Pocket" next
  fi
  ok "started again with the new tokens: ${keys[*]}"
}

# lib.sh reads compose/.env, so it comes after it; account.sh after lib.sh.
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
# shellcheck source=account.sh
source "$REPO_ROOT/scripts/account.sh"

case "${1:-status}" in
  status) cmd_status ;;
  rotate)
    days="$DAYS"
    if [ "${2:-}" = --days ]; then
      [[ "${3:-}" =~ ^[0-9]+$ ]] || die "--days takes a number of days"
      days="$3"
    fi
    cmd_rotate "$days"
    ;;
  *)
    sed -n '9,11s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
    exit 2
    ;;
esac
