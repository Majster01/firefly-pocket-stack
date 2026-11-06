#!/usr/bin/env bash
#
# Fills every generated secret: in the settings store (scripts/config.sh) on a
# server that has one, and on a new server, which starts one; otherwise in a
# hand-edited compose/.env, in place, as before the store.
#
# Safe to re-run: it only ever fills values that are currently EMPTY and never
# overwrites an existing secret. Rotating a secret is therefore a deliberate
# act: `scripts/firefly-pocket config unset <KEY>` (or, in a hand-edited .env,
# blank the line yourself), then run this again.
#
# Secrets are alphanumeric on purpose. They end up inside single-quoted SQL in
# initdb/01-create-databases.sh and inside Caddy/Compose variable expansion,
# and restricting the alphabet removes a whole class of quoting bugs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/compose/.env"
FP="$REPO_ROOT/scripts/firefly-pocket"
CADDY_IMAGE="caddy:2.11.7-alpine"

STORE=""
if [ -f "$REPO_ROOT/compose/config.json" ] || [ ! -f "$ENV_FILE" ]; then
  STORE=1
fi

# Random alphanumeric string of exactly $1 characters.
#
# Deliberately avoids the obvious `tr -dc ... < /dev/urandom | head -c N`:
# `head` exits as soon as it has N bytes, `tr` then dies on SIGPIPE, and under
# `set -o pipefail` that aborts the whole script. Reading a bounded chunk and
# looping until we have enough characters keeps every exit status clean.
randstr() {
  local n="$1" out=""
  while [ "${#out}" -lt "$n" ]; do
    out="$out$(LC_ALL=C head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${out:0:n}"
}

# The generated value for a given key, or empty if we do not manage that key.
# APP_KEY and STATIC_CRON_TOKEN must be EXACTLY 32 characters — Firefly III
# refuses to boot otherwise.
value_for() {
  case "$1" in
    FIREFLY_APP_KEY)          randstr 32 ;;
    STATIC_CRON_TOKEN)        randstr 32 ;;
    AUTO_IMPORT_SECRET)       randstr 32 ;;
    POSTGRES_SUPER_PASSWORD)  randstr 32 ;;
    FIREFLY_DB_PASSWORD)      randstr 32 ;;
    IMPORTER_DB_PASSWORD)     randstr 32 ;;
    IMPORTER_APP_KEY)         randstr 32 ;;
    FIREFLYX_API_TOKEN)       randstr 48 ;;
    SUGGESTER_TRIGGER_TOKEN)  randstr 48 ;;
    NEXT_APP_KEY)             randstr 32 ;;
    NEXT_DB_PASSWORD)         randstr 32 ;;
    NEXT_NOTIFY_TOKEN)        randstr 48 ;;
    RESTIC_PASSWORD)          randstr 32 ;;
    *)                        printf '' ;;
  esac
}

# base64url without padding, the encoding Web Push uses for VAPID keys.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Sets VAPID_PRIVATE and VAPID_PUBLIC to a fresh P-256 keypair: the raw 32-byte
# private scalar and the 65-byte uncompressed public point (0x04 || X || Y),
# both base64url — the format `web-push generate-vapid-keys` prints.
#
# The bytes are cut out of the SEC1 DER encoding of the key. For P-256 that is
# always 121 bytes: a 7-byte header, the 32-byte scalar, 25 bytes of curve
# parameters and the 65-byte public point. Checking the length (and the 0x04
# prefix) means an openssl with a different layout fails loudly instead of
# writing a key that quietly does not work. Called in the parent shell, not in
# a subshell: see the basic-auth comment further down.
make_vapid() {
  local der
  der="$(mktemp)"
  if ! openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null \
         | openssl ec -outform DER 2>/dev/null > "$der" ||
     [ "$(wc -c < "$der" | tr -d ' ')" -ne 121 ] ||
     [ "$(tail -c 65 "$der" | head -c 1 | od -An -tx1 | tr -d ' ')" != "04" ]; then
    rm -f "$der"
    return 1
  fi
  VAPID_PRIVATE="$(head -c 39 "$der" | tail -c 32 | b64url)"
  VAPID_PUBLIC="$(tail -c 65 "$der" | b64url)"
  rm -f "$der"
}

# A bcrypt hash of a fresh password for the importer UI, made by Caddy itself so
# the cost matches what Caddy expects. Sets BASIC_AUTH_PLAINTEXT and RAW_HASH.
# Called in the parent shell, never in a subshell: see the basic-auth comment
# further down.
make_hash() {
  BASIC_AUTH_PLAINTEXT=""
  RAW_HASH=""
  if ! command -v docker >/dev/null 2>&1; then
    echo "!! docker not found — cannot generate IMPORT_AUTH_HASH." >&2
    echo "   Run this script on the server, or make the hash by hand with:" >&2
    echo "     docker run --rm $CADDY_IMAGE caddy hash-password --plaintext 'yourpassword'" >&2
    return 0
  fi
  BASIC_AUTH_PLAINTEXT="$(randstr 24)"
  RAW_HASH="$(docker run --rm "$CADDY_IMAGE" \
    caddy hash-password --plaintext "$BASIC_AUTH_PLAINTEXT" 2>/dev/null | tr -d '\r\n')" || RAW_HASH=""
  if [ -z "$RAW_HASH" ]; then
    echo "!! 'caddy hash-password' produced nothing — leaving IMPORT_AUTH_HASH empty." >&2
    BASIC_AUTH_PLAINTEXT=""
  fi
}

print_password() {
  [ -n "$BASIC_AUTH_PLAINTEXT" ] || return 0
  cat <<EOF

  ============================================================
  Importer UI login — SAVE THIS NOW, it is not stored anywhere
  in plaintext and cannot be recovered.

      URL:      https://import.<DOMAIN>, or your IMPORT_HOSTNAME
      username: (whatever IMPORT_AUTH_USER is set to)
      password: $BASIC_AUTH_PLAINTEXT

  ============================================================
EOF
}

print_filled() {
  if [ -z "$FILLED" ]; then
    echo "==> Nothing to do — every managed secret already has a value."
  else
    echo "==> Filled:"
    for k in $FILLED; do echo "      $k"; done
  fi
}

# ---------------------------------------------------------------- store ---
if [ -n "$STORE" ]; then
  has() { "$FP" config has "$1"; }
  put() { "$FP" config set --no-render "$1" - <<<"$2" >/dev/null; FILLED="$FILLED $1"; }
  FILLED=""
  BASIC_AUTH_PLAINTEXT=""
  for key in FIREFLY_APP_KEY STATIC_CRON_TOKEN AUTO_IMPORT_SECRET POSTGRES_SUPER_PASSWORD \
             FIREFLY_DB_PASSWORD IMPORTER_DB_PASSWORD IMPORTER_APP_KEY FIREFLYX_API_TOKEN \
             SUGGESTER_TRIGGER_TOKEN NEXT_APP_KEY NEXT_DB_PASSWORD NEXT_NOTIFY_TOKEN RESTIC_PASSWORD; do
    has "$key" || put "$key" "$(value_for "$key")"
  done
  # A pair: both new, or neither.
  if ! has VAPID_PUBLIC_KEY && ! has VAPID_PRIVATE_KEY; then
    if command -v openssl >/dev/null 2>&1 && make_vapid; then
      put VAPID_PUBLIC_KEY "$VAPID_PUBLIC"
      put VAPID_PRIVATE_KEY "$VAPID_PRIVATE"
    else
      echo "!! could not generate the VAPID keypair with openssl — push alerts stay off." >&2
      echo "   Generate one elsewhere with npx web-push generate-vapid-keys, then config set both." >&2
    fi
  elif ! has VAPID_PUBLIC_KEY || ! has VAPID_PRIVATE_KEY; then
    echo "!! only one of VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY is set — leaving both alone." >&2
    echo "   They are a pair; config unset both to have a new pair generated." >&2
  fi
  if ! has VAPID_SUBJECT && has SITE_OWNER; then
    put VAPID_SUBJECT "mailto:$("$FP" config get SITE_OWNER)"
  fi
  if ! has IMPORT_AUTH_HASH; then
    make_hash
    [ -z "$RAW_HASH" ] || put IMPORT_AUTH_HASH "$RAW_HASH"
  fi
  "$FP" config render

  print_filled
  print_password
  # The setup wizard asks for the rest itself (scripts/setup.sh).
  [ -z "${FROM_SETUP:-}" ] || exit 0
  missing=""
  for key in DOMAIN ACME_EMAIL SITE_OWNER IMPORTER_FIREFLY_TOKEN SUGGESTER_FIREFLY_TOKEN \
             ENABLE_BANKING_APP_ID ENABLE_BANKING_PRIVATE_KEY ANTHROPIC_API_KEY NTFY_URL RESTIC_REPOSITORY; do
    has "$key" || missing="$missing $key"
  done
  if [ -n "$missing" ]; then
    echo
    echo "Still to set, each with scripts/firefly-pocket config set <KEY> <value> (README):"
    for key in $missing; do echo "  - $key"; done
  fi
  exit 0
fi

# ----------------------------------------------- a hand-edited .env ---
# A .env created before a secret was introduced has no line for it, and the
# loop below only fills existing empty lines. Append the missing ones first, so
# re-running this script on an existing server is all an upgrade needs.
for key in IMPORTER_DB_PASSWORD IMPORTER_APP_KEY FIREFLYX_API_TOKEN SUGGESTER_TRIGGER_TOKEN \
           VAPID_PUBLIC_KEY VAPID_PRIVATE_KEY \
           NEXT_APP_KEY NEXT_DB_PASSWORD NEXT_NOTIFY_TOKEN; do
  if ! grep -qE "^${key}=" "$ENV_FILE"; then
    printf '%s=\n' "$key" >> "$ENV_FILE"
  fi
done
# The contact the push services get with every Web Push: the site owner's
# address if there is one, otherwise the placeholder the README asks you to fix.
if ! grep -qE '^VAPID_SUBJECT=' "$ENV_FILE"; then
  owner="$(sed -n 's/^SITE_OWNER=//p' "$ENV_FILE" | head -n 1)"
  printf 'VAPID_SUBJECT=mailto:%s\n' "${owner:-you@example.com}" >> "$ENV_FILE"
fi

# The two halves are a pair, so they are generated together and only when BOTH
# are empty — filling one around a surviving other would silently break push.
VAPID_PRIVATE=""
VAPID_PUBLIC=""
if grep -qE '^VAPID_PUBLIC_KEY=[[:space:]]*$' "$ENV_FILE" &&
   grep -qE '^VAPID_PRIVATE_KEY=[[:space:]]*$' "$ENV_FILE"; then
  if ! { command -v openssl >/dev/null 2>&1 && make_vapid; }; then
    VAPID_PRIVATE=""
    VAPID_PUBLIC=""
    echo "!! could not generate the VAPID keypair with openssl — leaving VAPID_*_KEY empty." >&2
    echo "   Generate one elsewhere with:  npx web-push generate-vapid-keys" >&2
  fi
elif grep -qE '^VAPID_(PUBLIC|PRIVATE)_KEY=[[:space:]]*$' "$ENV_FILE"; then
  echo "!! only one of VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY is set — leaving both alone." >&2
  echo "   They are a pair; blank both lines to have a new pair generated." >&2
fi

BASIC_AUTH_PLAINTEXT=""
BASIC_AUTH_HASH=""

# Basic auth credentials for the importer UI, generated via Caddy itself so
# the bcrypt cost matches what Caddy expects.
#
# This runs HERE, in the parent shell, and deliberately not inside the rewrite
# loop below. Producing the hash via `new="$(make_hash)"` would run it in a
# subshell, so the assignment to BASIC_AUTH_PLAINTEXT would be discarded when
# that subshell exited — and since bcrypt is one-way, the password would be
# permanently lost while a working hash sat in .env, locking you out of the
# importer UI with no way to recover.
if grep -qE '^IMPORT_AUTH_HASH=[[:space:]]*$' "$ENV_FILE"; then
  make_hash
  # A bcrypt hash contains `$`, which Docker Compose would try to expand.
  # Store it doubled; Compose unescapes `$$` back to `$` for Caddy.
  [ -z "$RAW_HASH" ] || BASIC_AUTH_HASH="${RAW_HASH//\$/\$\$}"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
FILLED=""

while IFS= read -r line || [ -n "$line" ]; do
  key="${line%%=*}"
  current="${line#*=}"

  # Only touch real assignments (KEY=) whose value is currently empty.
  # This skips comments, blank lines, and anything already set.
  if [[ "$line" == *=* ]] &&
     [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] &&
     [ -z "$current" ]; then

    case "$key" in
      IMPORT_AUTH_HASH)  new="$BASIC_AUTH_HASH" ;;
      VAPID_PUBLIC_KEY)  new="$VAPID_PUBLIC" ;;
      VAPID_PRIVATE_KEY) new="$VAPID_PRIVATE" ;;
      *)                 new="$(value_for "$key")" ;;
    esac

    if [ -n "$new" ]; then
      printf '%s=%s\n' "$key" "$new" >> "$TMP"
      FILLED="$FILLED $key"
      continue
    fi
  fi

  printf '%s\n' "$line" >> "$TMP"
done < "$ENV_FILE"

cat "$TMP" > "$ENV_FILE"
chmod 600 "$ENV_FILE"

print_filled
print_password

cat <<'EOF'

Still to fill in by hand (see README):
  - DOMAIN, ACME_EMAIL, SITE_OWNER, TZ
  - IMPORTER_FIREFLY_TOKEN / SUGGESTER_FIREFLY_TOKEN  (stage 2, after registering)
  - ENABLE_BANKING_APP_ID  + compose/secrets/eb/private.pem
  - ANTHROPIC_API_KEY
  - NTFY_URL, RESTIC_REPOSITORY  (alerting and offsite backups)
  - VAPID_SUBJECT  (a mailto: address of yours for Web Push; the placeholder works but is not you)
EOF
if grep -qE '^VAPID_(PUBLIC|PRIVATE)_KEY=[[:space:]]*$' "$ENV_FILE"; then
  cat <<'EOF'
  - VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY  (push alerts in Firefly Pocket stay off until both are set;
    openssl was not usable here — run `npx web-push generate-vapid-keys` and paste them in)
EOF
fi
