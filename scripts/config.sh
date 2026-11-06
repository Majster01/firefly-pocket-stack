#!/usr/bin/env bash
#
# Firefly Pocket's settings (Setup UI step 1). Run it as
#
#     scripts/firefly-pocket config list               every setting; a secret only says it is set
#     scripts/firefly-pocket config get <KEY>          one value; a secret shows its last four characters
#     scripts/firefly-pocket config set <KEY> <value>  check the value, keep it, write compose/.env
#     scripts/firefly-pocket config set <KEY> -        the same, the value read from stdin, so a key
#                                                      stays out of the shell's history. --force:
#                                                      even though .env was edited by hand
#     scripts/firefly-pocket config unset <KEY>        back to its default (a secret: no value)
#     scripts/firefly-pocket config has <KEY>          exit 0 when it has a value, for scripts
#     scripts/firefly-pocket config render [--force]   write compose/.env from the store (the deploy does)
#     scripts/firefly-pocket config import             move a hand-edited compose/.env into the store, once
#
# The store: compose/config.json holds the plain settings, compose/secrets/env/
# one file per secret, mode 600. compose/.env is written from those two and from
# nothing else, so nobody edits it by hand: the deploy writes it again, and stops
# with an alert when it was changed since it was last written. scripts/settings.json
# says what each setting is, how a value is checked and what its default is.
#
# A server whose .env is still edited by hand has no compose/config.json, and
# then this changes nothing: set refuses, and the deploy writes no .env.

set -euo pipefail
shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/compose"
SCHEMA="$REPO_ROOT/scripts/settings.json"
CONFIG="$COMPOSE_DIR/config.json"
SECRETS="$COMPOSE_DIR/secrets/env"
ENV_FILE="$COMPOSE_DIR/.env"
# The sha256 of the .env this last wrote: a different .env was edited by hand.
RENDERED="$COMPOSE_DIR/.env.rendered"

die() { echo "FATAL: $*" >&2; exit 1; }

# ------------------------------------------------------------- schema ---
jq -e 'type == "object"' "$SCHEMA" >/dev/null 2>&1 || die "$SCHEMA is not a JSON object"
KEYS=()
declare -A KIND=() CHECK=() OMIT=() DEFAULT=()
while IFS=$'\t' read -r key kind check omit default; do
  KEYS+=("$key")
  KIND[$key]="$kind"
  CHECK[$key]="$check"
  OMIT[$key]="$omit"
  DEFAULT[$key]="$default"
done < <(jq -r 'to_entries[] | [.key, .value.kind, .value.check, (.value.omit_when_empty // false | tostring), (.value.default // "")] | @tsv' "$SCHEMA")
[ "${#KEYS[@]}" -gt 0 ] || die "no settings in $SCHEMA"

known() { [[ -v KIND[$1] ]] || die "$1 is not a setting (scripts/settings.json lists them)"; }
secret() { [ "${KIND[$1]}" != config ]; }

# ------------------------------------------------------------- checks ---
# check_value <check> <value>: nothing when the value passes, else what it
# should look like. Values go into .env unquoted, as compose and lib.sh's
# load_env read them, so none may hold a newline, and those compose would
# expand or cut ($, a " #") are refused where a person could type one.
check_value() {
  local v="$2" re
  case "$1" in
    domain)
      re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'
      [[ ${#v} -le 253 && "$v" =~ $re ]] || echo "a host name in lower case, such as example.com" ;;
    email)
      re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
      [[ "$v" =~ $re ]] || echo "an email address, such as you@example.com" ;;
    contact)
      re='^(mailto:[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+|https://[^[:space:]$\\]+)$'
      [[ "$v" =~ $re ]] || echo "mailto: and an email address, or an https:// URL" ;;
    url)
      re='^https?://[^[:space:]$\\]+$'
      [[ "$v" =~ $re ]] || echo "an http:// or https:// URL" ;;
    text)
      if [[ ${#v} -gt 200 || "$v" == *[\$\\\#\"]* || "$v" == [[:space:]\']* || "$v" == *[[:space:]] || "$v" =~ [[:cntrl:]] ]]; then
        echo "plain text up to 200 characters, without \$, \\, # or \", and no space at either end"
      fi ;;
    timezone)
      re='^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$'
      if ! [[ "$v" =~ $re ]] || { [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/$v" ]; }; then
        echo "an IANA timezone, such as Europe/Ljubljana"
      fi ;;
    word)
      re='^[A-Za-z0-9._-]{1,64}$'
      [[ "$v" =~ $re ]] || echo "letters, digits, dots, dashes and underscores" ;;
    count)
      re='^[1-9][0-9]{0,5}$'
      [[ "$v" =~ $re ]] || echo "a whole number above 0" ;;
    bool)
      [[ "$v" == true || "$v" == false ]] || echo "true or false" ;;
    fraction)
      re='^(0(\.[0-9]+)?|1(\.0+)?)$'
      [[ "$v" =~ $re ]] || echo "a number from 0 to 1, such as 0.6" ;;
    model)
      re='^(claude|gemini)-[a-z0-9.-]+$'
      [[ "$v" =~ $re ]] || echo "a claude-* or gemini-* model name" ;;
    bcrypt)
      # shellcheck disable=SC2016  # the $ are the hash's, not variables
      re='^\$2[aby]\$[0-9]{2}\$[./A-Za-z0-9]{53}$'
      [[ "$v" =~ $re ]] || echo "a bcrypt hash, as caddy hash-password prints it" ;;
    key32)
      re='^[A-Za-z0-9]{32}$'
      [[ "$v" =~ $re ]] || echo "exactly 32 letters and digits" ;;
    password)
      re='^[A-Za-z0-9]{16,}$'
      [[ "$v" =~ $re ]] || echo "at least 16 letters and digits" ;;
    appkey)
      re='^(base64:[A-Za-z0-9+/]{43}=|[A-Za-z0-9]{32,})$'
      [[ "$v" =~ $re ]] || echo "at least 32 letters and digits, or base64: and a 32-byte key" ;;
    token32)
      re='^[A-Za-z0-9]{32,}$'
      [[ "$v" =~ $re ]] || echo "at least 32 letters and digits" ;;
    pat)
      re='^[A-Za-z0-9._-]{40,}$'
      [[ "$v" =~ $re ]] || echo "a Firefly III Personal Access Token, the long one it shows once" ;;
    apikey)
      re='^[A-Za-z0-9._-]{16,}$'
      [[ "$v" =~ $re ]] || echo "an API key: at least 16 letters, digits, dots, dashes and underscores" ;;
    base64)
      re='^[A-Za-z0-9+/]{100,}={0,2}$'
      [[ "$v" =~ $re ]] || echo "the base64 body of the PEM on one line (scripts/set-eb-key.sh makes it)" ;;
    base64url)
      re='^[A-Za-z0-9_-]{40,}$'
      [[ "$v" =~ $re ]] || echo "a base64url key, as web-push generate-vapid-keys prints it" ;;
    uuid)
      re='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
      [[ "$v" =~ $re ]] || echo "an application ID, such as 1b4e28ba-2fa1-11d2-883f-0016d3cca427" ;;
    nospace)
      re='^[^[:space:]$\\]+$'
      [[ "$v" =~ $re ]] || echo "one word, without spaces, \$ or \\" ;;
    line)
      [[ "$v" != *$'\n'* && "$v" != *$'\r'* ]] || echo "one line" ;;
    *)
      echo "checked by '$1', which this version does not know" ;;
  esac
}

# -------------------------------------------------------------- store ---
declare -A CFG=()
load_config() {
  CFG=()
  [ -f "$CONFIG" ] || return 0
  jq -e 'type == "object" and all(.[]; type == "string")' "$CONFIG" >/dev/null 2>&1 \
    || die "$CONFIG is not a JSON object of strings"
  local k v
  while IFS= read -r -d '' k && IFS= read -r -d '' v; do
    CFG[$k]="$v"
  done < <(jq -j 'to_entries[] | "\(.key)\u0000\(.value)\u0000"' "$CONFIG")
}

# A fresh server gets an empty store; a hand-edited .env must be imported first,
# or its values would be dropped at the next render.
open_store() {
  [ -f "$CONFIG" ] && return 0
  if [ -f "$ENV_FILE" ]; then
    die "compose/.env is still edited by hand. Move it into the store, once, with: scripts/firefly-pocket config import"
  fi
  mkdir -p "$SECRETS"
  chmod 700 "$SECRETS"
  (umask 077 && printf '{}\n' > "$CONFIG")
}

need_store() {
  [ -f "$CONFIG" ] || die "this server keeps its settings in a hand-edited compose/.env. Move them into the store, once, with: scripts/firefly-pocket config import"
}

# put <key> <value> / drop <key>: change the store, nothing else.
put() {
  local tmp
  if secret "$1"; then
    tmp="$(mktemp "$SECRETS/.$1.XXXXXX")"
    printf '%s' "$2" > "$tmp"
    mv "$tmp" "$SECRETS/$1"
  else
    tmp="$(mktemp "$CONFIG.XXXXXX")"
    jq --arg k "$1" --arg v "$2" '.[$k] = $v' "$CONFIG" > "$tmp"
    mv "$tmp" "$CONFIG"
  fi
}
drop() {
  local tmp
  if secret "$1"; then
    rm -f "$SECRETS/$1"
  else
    tmp="$(mktemp "$CONFIG.XXXXXX")"
    jq --arg k "$1" 'del(.[$k])' "$CONFIG" > "$tmp"
    mv "$tmp" "$CONFIG"
  fi
}

# value_of <key>: what .env gets for it. load_config first.
value_of() {
  if ! secret "$1"; then
    if [[ -v CFG[$1] ]]; then printf '%s' "${CFG[$1]}"; else printf '%s' "${DEFAULT[$1]}"; fi
  elif [ -f "$SECRETS/$1" ]; then
    cat "$SECRETS/$1"
  fi
}

# Files in secrets/env/ that are no setting: lines an imported .env had that
# nothing here knows, kept so that the import loses no value.
extras() {
  local f
  for f in "$SECRETS"/*; do
    [ -f "$f" ] || continue
    [[ -v KIND[${f##*/}] ]] || printf '%s\n' "${f##*/}"
  done
}

masked() {
  if [ -z "$1" ]; then echo "not set"; elif [ "${#1}" -le 8 ]; then echo "set"; else echo "set, ...${1: -4}"; fi
}

# ------------------------------------------------------------- render ---
# write_env <file>: the .env the store makes. load_config first.
write_env() {
  local key value extra
  {
    echo "# Written by scripts/firefly-pocket config from compose/config.json and compose/secrets/env/."
    echo "# Do not edit it: the deploy writes it again, and stops at a hand edit. Change a value with"
    echo "#   scripts/firefly-pocket config set <KEY> <value>"
    for key in "${KEYS[@]}"; do
      value="$(value_of "$key")"
      if [ -z "$value" ] && [ "${OMIT[$key]}" = true ]; then
        continue
      fi
      # Compose would expand the hash's $; it reads $$ as one (lib.sh undoes it).
      if [ "$key" = IMPORT_AUTH_HASH ]; then
        value="${value//\$/\$\$}"
      fi
      printf '%s=%s\n' "$key" "$value"
    done
    extra="$(extras)"
    if [ -n "$extra" ]; then
      echo "# Kept from the .env the store was imported from; scripts/settings.json does not know them."
      while IFS= read -r key; do
        printf '%s=%s\n' "$key" "$(cat "$SECRETS/$key")"
      done <<<"$extra"
    fi
  } > "$1"
}

# The settings a hand edit changed in compose/.env. Names only: the message
# goes into alerts.
edited_keys() {
  local tmp key now_order=() want_order=()
  local -A now=() want=()
  load_config
  tmp="$(mktemp "$COMPOSE_DIR/.env.XXXXXX")"
  write_env "$tmp"
  read_env "$ENV_FILE" now now_order
  read_env "$tmp" want want_order
  rm -f "$tmp"
  for key in "${now_order[@]}"; do
    [[ -v want[$key] && "${want[$key]}" == "${now[$key]}" ]] || printf '%s ' "$key"
  done
  for key in "${want_order[@]}"; do
    [[ -v now[$key] ]] || printf '%s ' "$key"
  done
}

# Before the store changes, and before .env is written: a .env that is not the
# one written last was edited by hand, and writing it again would lose that.
not_edited() {
  [ -z "${FORCE:-}" ] && [ -f "$ENV_FILE" ] && [ -f "$RENDERED" ] || return 0
  [ "$(sha256sum < "$ENV_FILE")" != "$(cat "$RENDERED")" ] || return 0
  local keys
  keys="$(edited_keys)"
  die "compose/.env was edited by hand since it was last written${keys:+ (${keys% } differ from the settings)}, so nothing was changed. Put an edit in with: scripts/firefly-pocket config set --force <KEY> <value>. Or drop the edits with: scripts/firefly-pocket config render --force"
}

render() {
  need_store
  load_config
  not_edited
  local tmp
  tmp="$(mktemp "$COMPOSE_DIR/.env.XXXXXX")"
  write_env "$tmp"
  mv "$tmp" "$ENV_FILE"
  sha256sum < "$ENV_FILE" > "$RENDERED"
}

# ------------------------------------------------------------- import ---
# read_env <file> <assoc-array name> <order-array name>: KEY=VALUE lines, as
# lib.sh's load_env reads them, a later line winning.
read_env() {
  local -n into="$2" keys="$3"
  local line key
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    [[ -v into[$key] ]] || keys+=("$key")
    # shellcheck disable=SC2004  # an associative array: the $ is needed
    into[$key]="${line#*=}"
  done < "$1"
}

cmd_import() {
  [ ! -f "$CONFIG" ] || die "the settings are in the store already (compose/config.json)"
  [ -f "$ENV_FILE" ] || die "there is no compose/.env to import"
  [ ! -e "$SECRETS" ] || die "$SECRETS is left from an earlier try. Move it away, then import again."

  local work key value problem
  local -A old=() new=()
  local order=() new_order=() problems=() kept=() added=() changed=()
  work="$(mktemp -d "$COMPOSE_DIR/.import.XXXXXX")"
  # shellcheck disable=SC2064  # $work is fixed now
  trap "rm -rf '$work'" EXIT
  chmod 700 "$work"
  mkdir -m 700 "$work/env"
  (umask 077 && printf '{}\n' > "$work/config.json")

  read_env "$ENV_FILE" old order

  # Build the store beside the real one, from every line of the .env.
  CONFIG="$work/config.json" SECRETS="$work/env"
  for key in "${order[@]}"; do
    value="${old[$key]}"
    if ! [[ -v KIND[$key] ]]; then
      printf '%s' "$value" > "$SECRETS/$key"
      kept+=("$key")
      continue
    fi
    [ "$key" = IMPORT_AUTH_HASH ] && value="${value//\$\$/\$}"
    if [ -n "$value" ]; then
      problem="$(check_value "${CHECK[$key]}" "$value")"
      if [ -n "$problem" ]; then
        problems+=("$key: $problem")
        continue
      fi
    fi
    # An empty secret is no secret; an empty plain setting stays empty, as
    # compose then uses its own default just as before.
    if secret "$key"; then
      [ -z "$value" ] || put "$key" "$value"
    else
      put "$key" "$value"
    fi
  done
  if [ "${#problems[@]}" -gt 0 ]; then
    printf '  %s\n' "${problems[@]}" >&2
    die "these values in compose/.env do not pass their check, so nothing was changed. Correct them in .env, then import again."
  fi

  # Write the .env from it, and prove it holds every value the old one did.
  ENV_FILE="$work/.env" RENDERED="$work/.env.rendered" FORCE=1
  render
  read_env "$ENV_FILE" new new_order
  for key in "${order[@]}"; do
    if [[ -v new[$key] ]]; then
      [ "${new[$key]}" = "${old[$key]}" ] || changed+=("$key")
    elif [ -n "${old[$key]}" ] || [ "${OMIT[$key]:-}" != true ]; then
      changed+=("$key")
    fi
  done
  [ "${#changed[@]}" -eq 0 ] || die "the written .env would change ${changed[*]}, so nothing was changed. This is a bug: please report it."
  for key in "${new_order[@]}"; do
    [[ -v old[$key] ]] || added+=("$key=${new[$key]}")
  done

  # Swap it in. config.json goes last: until it is there, the deploy and every
  # script go on reading .env, which by then already holds the same values.
  (umask 077 && cp "$COMPOSE_DIR/.env" "$COMPOSE_DIR/.env.before-import")
  chmod 600 "$COMPOSE_DIR/.env.before-import"
  mv "$work/env" "$COMPOSE_DIR/secrets/env"
  mv "$work/.env" "$COMPOSE_DIR/.env"
  mv "$work/.env.rendered" "$COMPOSE_DIR/.env.rendered"
  mv "$work/config.json" "$COMPOSE_DIR/config.json"

  echo "==> compose/.env is in the store now: all ${#order[@]} of its settings, each value as it was"
  [ "${#kept[@]}" -eq 0 ] || echo "    kept as they were, though no setting reads them: ${kept[*]}"
  [ "${#added[@]}" -eq 0 ] || echo "    added with the value compose used for them already: ${added[*]}"
  echo "    the .env from before is compose/.env.before-import"
  echo "From now on change a setting with scripts/firefly-pocket config set <KEY> <value>."
  echo "A hand edit to compose/.env stops the next deploy, with an alert."
}

# ----------------------------------------------------------- commands ---
read_secret_value() {
  local key="$1" value=""
  if [ -t 0 ]; then
    IFS= read -r -s -p "$key: " value
    echo >&2
  else
    IFS= read -r value || true
  fi
  printf '%s' "$value"
}

cmd_set() {
  local no_render=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-render) no_render=1; shift ;;
      --force) FORCE=1; shift ;;
      *) break ;;
    esac
  done
  [ $# -eq 2 ] || die "usage: firefly-pocket config set [--force] <KEY> <value>, or - for the value to be read from stdin"
  local key="$1" value="$2" problem
  known "$key"
  [ "$value" != - ] || value="$(read_secret_value "$key")"
  [ -n "$value" ] || die "$key: no value. To go back to the default, or to none: firefly-pocket config unset $key"
  problem="$(check_value "${CHECK[$key]}" "$value")"
  [ -z "$problem" ] || die "$key: $problem"
  open_store
  not_edited
  put "$key" "$value"
  [ -n "$no_render" ] || render
  if secret "$key"; then echo "$key: $(masked "$value")"; else echo "$key=$value"; fi
}

cmd_unset() {
  [ $# -eq 1 ] || die "usage: firefly-pocket config unset <KEY>"
  known "$1"
  need_store
  not_edited
  drop "$1"
  render
  if secret "$1"; then echo "$1: not set"; else echo "$1=${DEFAULT[$1]} (the default)"; fi
}

cmd_get() {
  [ $# -eq 1 ] || die "usage: firefly-pocket config get <KEY>"
  known "$1"
  need_store
  load_config
  if secret "$1"; then masked "$(value_of "$1")"; else value_of "$1"; echo; fi
}

cmd_has() {
  [ $# -eq 1 ] || die "usage: firefly-pocket config has <KEY>"
  known "$1"
  [ -f "$CONFIG" ] || return 1
  load_config
  [ -n "$(value_of "$1")" ]
}

cmd_list() {
  need_store
  load_config
  local key value
  for key in "${KEYS[@]}"; do
    value="$(value_of "$key")"
    if secret "$key"; then
      value="$(masked "$value")"
    elif ! [[ -v CFG[$key] ]]; then
      value="${value:+$value (default)}"
      value="${value:-not set}"
    fi
    printf '%-27s %s\n' "$key" "$value"
  done
  while IFS= read -r key; do
    [ -z "$key" ] || printf '%-27s %s\n' "$key" "kept from the imported .env"
  done <<<"$(extras)"
}

command="${1:-}"
[ $# -eq 0 ] || shift
case "$command" in
  set)    cmd_set "$@" ;;
  unset)  cmd_unset "$@" ;;
  get)    cmd_get "$@" ;;
  has)    cmd_has "$@" ;;
  list)   cmd_list "$@" ;;
  import) cmd_import "$@" ;;
  render)
    [ "${1:-}" != --force ] || FORCE=1
    render
    ;;
  *)
    sed -n '3,15s/^# \{0,1\}//p' "${BASH_SOURCE[0]}" >&2
    exit 2
    ;;
esac
