#!/usr/bin/env bash
#
# Tests of the settings store (scripts/config.sh), for CI's compose job. Needs
# bash, jq and sha256sum, no Docker: it works on a copy of scripts/ and compose/
# in a temporary directory, never on this checkout's compose/.env.
#
#   1. scripts/settings.json against .env.example and docker-compose.yml: the
#      same settings, each default the one compose uses, each check one that
#      config.sh knows
#   2. a new server: config set writes .env; every value .env.example shows
#      passes its check; bad values are refused and change nothing
#   3. secrets: kept in their own files, mode 600, never in config.json, shown
#      only by their last four characters
#   4. a hand edit to .env: refused, naming the setting and not its value, then
#      put in with set --force or dropped with render --force
#   5. import: a server-like hand-edited .env comes out with every value as it
#      was, keeps the lines no setting reads, and refuses a bad value whole

# ok always succeeds, so `test && ok ... || fail ...` is an if/else here; and the
# single-quoted $ in the test values are meant literally.
# shellcheck disable=SC2015,SC2016

set -euo pipefail
shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
# expect_refused <what> <command...>: the command must fail.
expect_refused() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$what was accepted"; else ok "$what is refused"; fi
}

echo "==> scripts/settings.json against .env.example and docker-compose.yml"
schema="$REPO_ROOT/scripts/settings.json"
example="$REPO_ROOT/compose/.env.example"
compose_file="$REPO_ROOT/compose/docker-compose.yml"
if diff <(jq -r 'keys_unsorted[]' "$schema" | sort) \
        <(grep -oE '^#?[A-Z_][A-Z0-9_]*=' "$example" | tr -d '#=' | sort -u); then
  ok "the same $(jq length "$schema") settings as .env.example"
else
  fail "settings.json and .env.example list different settings (above)"
fi
unknown="$(comm -23 <(grep -oE '\$\{[A-Z_][A-Z0-9_]*' "$compose_file" | cut -c3- | sort -u) \
                    <(jq -r 'keys[]' "$schema" | sort))"
[ -z "$unknown" ] && ok "every variable compose reads is a setting" || fail "compose reads settings.json does not list: $unknown"
while IFS=' ' read -r key literal; do
  default="$(jq -r --arg k "$key" '.[$k].default // ""' "$schema")"
  if [ -n "$default" ] && [ "$default" != "$literal" ]; then
    fail "$key defaults to '$default', but compose uses '$literal' when it is empty"
  fi
done < <(grep -oE '\$\{[A-Z_][A-Z0-9_]*:-[^}$]*\}' "$compose_file" | sed -E 's/^\$\{([A-Z0-9_]+):-(.*)\}$/\1 \2/' | sort -u)
ok "each default is the one compose uses"
for check in $(jq -r '[.[].check] | unique[]' "$schema"); do
  grep -qE "^    ${check}\)" "$REPO_ROOT/scripts/config.sh" || fail "config.sh has no check called $check"
done
ok "config.sh knows every check settings.json names"

# A copy to work in: the scripts, and compose/ without any .env or store.
mkdir -p "$work/repo"
cp -r "$REPO_ROOT/scripts" "$REPO_ROOT/compose" "$work/repo/"
cd "$work/repo"
rm -rf compose/.env compose/config.json compose/secrets/env compose/.env.rendered compose/.env.before-import
fp() { scripts/firefly-pocket config "$@"; }
value() { sed -n "s/^$1=//p" compose/.env; }

echo "==> a new server"
fp set DOMAIN example.com >/dev/null
[ -f compose/.env ] && [ "$(stat -c %a compose/.env)" = 600 ] && ok "config set writes compose/.env, mode 600" || fail "no compose/.env, or not mode 600"
grep -qE '^[A-Z_]+_HOSTNAME=' compose/.env && fail ".env sets a hostname nobody set" || ok "no hostname line: compose derives them from DOMAIN"
[ "$(value TZ)" = Etc/UTC ] && [ "$(value IMPORT_AUTH_USER)" = admin ] && ok "unset settings get their defaults" || fail "TZ or IMPORT_AUTH_USER is not its default"
bad=""
while IFS='=' read -r key val; do
  [ -n "$val" ] || continue
  fp set "$key" "$val" >/dev/null 2>&1 || bad="$bad $key=$val"
done < <(grep -E '^[A-Z_][A-Z0-9_]*=' compose/.env.example)
[ -z "$bad" ] && ok "every value .env.example shows passes its check" || fail "refused:$bad"
before="$(sha256sum compose/config.json compose/.env)"
expect_refused "an unknown setting" fp set NO_SUCH_SETTING 1
expect_refused "a domain in capitals" fp set DOMAIN Example.COM
expect_refused "a timezone that does not exist" fp set TZ Mars/Olympus_Mons
expect_refused "a confidence above 1" fp set SUGGESTER_MIN_CONFIDENCE 2
expect_refused "a \$ in a name" fp set LEGAL_OWNER_NAME 'A $HOME'
expect_refused "an empty value" fp set ACME_EMAIL ''
[ "$(sha256sum compose/config.json compose/.env)" = "$before" ] && ok "a refused value changes nothing" || fail "a refused value changed the store or .env"
fp unset TZ >/dev/null && [ "$(value TZ)" = Etc/UTC ] && ok "unset goes back to the default" || fail "unset TZ did not give Etc/UTC"

echo "==> secrets"
key="sk-ant-api03-$(printf 'x%.0s' {1..40})WXYZ"
fp set ANTHROPIC_API_KEY - <<<"$key" >/dev/null
[ "$(value ANTHROPIC_API_KEY)" = "$key" ] && ok "a value read from stdin reaches .env" || fail "ANTHROPIC_API_KEY is not in .env"
[ "$(stat -c %a compose/secrets/env/ANTHROPIC_API_KEY)" = 600 ] && [ "$(stat -c %a compose/secrets/env)" = 700 ] \
  && ok "its own file, mode 600, in a directory of mode 700" || fail "secret file or directory modes are wrong"
grep -qF "$key" compose/config.json && fail "config.json holds the secret" || ok "config.json does not hold it"
listed="$(fp list)"
[ "$(fp get ANTHROPIC_API_KEY)" = "set, ...WXYZ" ] && grep -q '^ANTHROPIC_API_KEY  *set, \.\.\.WXYZ$' <<<"$listed" \
  && ! grep -qF "$key" <<<"$listed" && ok "get and list show only its last four characters" || fail "get or list shows the secret"
fp has ANTHROPIC_API_KEY && ! fp has GEMINI_API_KEY && ok "has says which are set" || fail "has is wrong"

echo "==> a hand edit to .env"
sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=sk-edited-by-hand-0000000000|; s|^IMPORT_LOOKBACK_DAYS=.*|IMPORT_LOOKBACK_DAYS=9|" compose/.env
echo "STRAY=1" >> compose/.env
edited="$(sha256sum compose/.env)"
if out="$(fp set TZ Europe/Ljubljana 2>&1)"; then
  fail "config set went ahead over a hand edit"
else
  [ "$(sha256sum compose/.env)" = "$edited" ] && [ "$(jq -r '.TZ // "unset"' compose/config.json)" = unset ] \
    && ok "config set refuses and changes nothing" || fail "config set changed something before refusing"
  named="$(sed -nE 's/.*\(([A-Z_ ]+) differ from the settings\).*/\1/p' <<<"$out" | tr ' ' '\n' | sort | tr '\n' ' ')"
  [ "$named" = "ANTHROPIC_API_KEY IMPORT_LOOKBACK_DAYS STRAY " ] && ! grep -q 'sk-edited' <<<"$out" \
    && ok "the refusal names the settings, not their values" || fail "the refusal says: $out"
fi
expect_refused "render over a hand edit" fp render
fp set --force IMPORT_LOOKBACK_DAYS 9 >/dev/null
[ "$(value IMPORT_LOOKBACK_DAYS)" = 9 ] && [ "$(value ANTHROPIC_API_KEY)" = "$key" ] && ! grep -q '^STRAY=' compose/.env \
  && ok "set --force keeps that edit and drops the others" || fail "set --force did not"
fp render >/dev/null && ok "after that, render goes ahead" || fail "render still refuses"

echo "==> import of a hand-edited .env"
rm -rf compose/.env compose/config.json compose/secrets/env compose/.env.rendered
rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1" || true; }
declare -A fake=(
  [FIREFLY_APP_KEY]="$(rand 32)" [STATIC_CRON_TOKEN]="$(rand 32)" [AUTO_IMPORT_SECRET]="$(rand 32)"
  [POSTGRES_SUPER_PASSWORD]="$(rand 32)" [FIREFLY_DB_PASSWORD]="$(rand 32)" [IMPORTER_DB_PASSWORD]="$(rand 32)"
  [IMPORTER_APP_KEY]="$(rand 32)" [FIREFLYX_API_TOKEN]="$(rand 48)" [NEXT_APP_KEY]="$(rand 32)"
  [NEXT_DB_PASSWORD]="$(rand 32)" [NEXT_NOTIFY_TOKEN]="$(rand 48)" [SUGGESTER_TRIGGER_TOKEN]="$(rand 48)"
  [IMPORT_AUTH_HASH]="\$\$2a\$\$14\$\$$(rand 53)" [RESTIC_PASSWORD]="a hand-made one/with+symbols!"
  [IMPORTER_FIREFLY_TOKEN]="eyJ0$(rand 600)" [SUGGESTER_FIREFLY_TOKEN]="eyJ0$(rand 600)"
  [ENABLE_BANKING_APP_ID]="1b4e28ba-2fa1-11d2-883f-0016d3cca427" [ENABLE_BANKING_PRIVATE_KEY]="$(rand 1600)"
  [VAPID_PUBLIC_KEY]="$(rand 87)" [VAPID_PRIVATE_KEY]="$(rand 43)" [NTFY_URL]="https://ntfy.sh/$(rand 20)"
  [TZ]="" [ACME_EMAIL]="me@example.org" [SITE_OWNER]="me@example.org"
)
# Every line of .env.example as a server has it, but no DOMAIN and no
# SUGGESTER_MAX_PER_RUN (lines it never got), its four hostnames, and two lines
# from before that nothing reads.
while IFS= read -r line; do
  k="${line%%=*}"
  case "$line" in
    DOMAIN=*|SUGGESTER_MAX_PER_RUN=*) ;;
    [A-Z]*=*) if [[ -v fake[$k] ]]; then echo "$k=${fake[$k]}"; else echo "$line"; fi ;;
    *) echo "$line" ;;
  esac
done < compose/.env.example > compose/.env
printf '%s\n' FIREFLY_HOSTNAME=firefly.example.org NEXT_HOSTNAME=next.example.org \
  IMPORT_HOSTNAME=import.example.org LEGAL_HOSTNAME=legal.example.org \
  LOGS_HOSTNAME=logs.example.org 'PICO_DB_PASSWORD=old$$one' >> compose/.env
cp compose/.env hand.env

expect_refused "config set beside a hand-edited .env" fp set TZ Europe/Ljubljana
sed 's/^ACME_EMAIL=.*/ACME_EMAIL=not an email/' hand.env > compose/.env
expect_refused "an import with a bad value" fp import
[ ! -e compose/config.json ] && [ ! -e compose/secrets/env ] && cmp -s compose/.env <(sed 's/^ACME_EMAIL=.*/ACME_EMAIL=not an email/' hand.env) \
  && ok "a refused import leaves everything as it was" || fail "a refused import changed something"
cp hand.env compose/.env
fp import >/dev/null
lines() { grep -E '^[A-Z_][A-Z0-9_]*=' "$1" | sort; }
added="$(comm -13 <(lines hand.env) <(lines compose/.env))"
removed="$(comm -23 <(lines hand.env) <(lines compose/.env))"
[ -z "$removed" ] && ok "every line of the old .env is in the new one, unchanged" || fail "lost or changed: $removed"
[ "$added" = "$(printf 'DOMAIN=\nSUGGESTER_MAX_PER_RUN=50')" ] && ok "added only what compose used already: $(tr '\n' ' ' <<<"$added")" || fail "added: $added"
cmp -s hand.env compose/.env.before-import && [ "$(stat -c %a compose/.env.before-import)" = 600 ] \
  && ok "the old .env is kept as .env.before-import, mode 600" || fail ".env.before-import is missing or not mode 600"
leak=""
for k in FIREFLY_APP_KEY ENABLE_BANKING_PRIVATE_KEY IMPORTER_FIREFLY_TOKEN NTFY_URL RESTIC_PASSWORD; do
  grep -qF "${fake[$k]}" compose/config.json && leak="$leak $k"
done
[ -z "$leak" ] && ok "config.json holds none of the secrets" || fail "config.json holds:$leak"
[ "$(fp get IMPORT_AUTH_HASH)" != "not set" ] && [ "$(cut -c1-7 compose/secrets/env/IMPORT_AUTH_HASH)" = '$2a$14$' ] \
  && ok "the importer password's hash is kept with single \$, written doubled" || fail "IMPORT_AUTH_HASH was not undoubled"
grep -q '^PICO_DB_PASSWORD  *kept from the imported .env$' <<<"$(fp list)" && ok "list shows the lines nothing reads" || fail "list misses PICO_DB_PASSWORD"
expect_refused "a second import" fp import
fp set IMPORT_LOOKBACK_DAYS 7 >/dev/null && [ "$(value IMPORT_LOOKBACK_DAYS)" = 7 ] && [ "$(value LOGS_HOSTNAME)" = logs.example.org ] \
  && ok "after the import, config set works and the kept lines stay" || fail "config set after the import"

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures failed"
  exit 1
fi
echo "the settings store passes"
