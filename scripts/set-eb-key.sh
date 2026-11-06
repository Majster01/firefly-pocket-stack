#!/usr/bin/env bash
#
# Point this stack at an Enable Banking application.
#
#   ./scripts/set-eb-key.sh <path-to-private.pem> [application-id]
#
# Converts the PEM to the single-line base64 form the Data Importer actually
# accepts, keeps it (in the settings store, scripts/config.sh, or in a
# hand-edited compose/.env), then asks the Enable Banking API what the
# application is — most importantly whether it is SANDBOX or PRODUCTION.
#
# Why base64 rather than a path: the importer runs the value through
# filter_var(FILTER_VALIDATE_URL) and rejects anything URL-shaped, logging
# "Private key is an URL" and failing validation with a bare {"result":"NOK"}
# in the UI. It detects base64 and rebuilds the PEM armour itself.
#
# Why the environment check: a SANDBOX application can only ever see the
# "Mock ASPSP" simulator. Real banks are absent from the sandbox catalogue
# entirely, so the UI simply shows nothing useful and gives no reason why.
# Free production access is available in "restricted mode" — activate it by
# linking your own accounts in the Enable Banking control panel.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/compose/.env"

PEM="${1:-}"
APP_ID_ARG="${2:-}"

if [ -z "$PEM" ] || [ ! -f "$PEM" ]; then
  echo "usage: $0 <path-to-private.pem> [application-id]" >&2
  exit 1
fi

# --- validate the key before touching anything --------------------------
if ! openssl pkey -in "$PEM" -noout >/dev/null 2>&1; then
  echo "FATAL: $PEM is not a readable private key." >&2
  exit 1
fi

B64="$(grep -v -- '-----' "$PEM" | tr -d '\n\r')"
if [ -z "$B64" ]; then
  echo "FATAL: could not extract a base64 body from $PEM." >&2
  exit 1
fi

# Prove the reconstruction the importer performs is lossless.
REBUILT="$(mktemp)"
trap 'rm -f "$REBUILT"' EXIT
{
  echo "-----BEGIN PRIVATE KEY-----"
  echo "$B64" | fold -w64
  echo "-----END PRIVATE KEY-----"
} > "$REBUILT"
if ! diff -q \
     <(openssl pkey -in "$PEM"     -outform DER 2>/dev/null | openssl base64 -A) \
     <(openssl pkey -in "$REBUILT" -outform DER 2>/dev/null | openssl base64 -A) >/dev/null 2>&1; then
  echo "FATAL: base64 round-trip did not reproduce the key. Refusing to write." >&2
  exit 1
fi
echo "==> key validated (round-trip is lossless, ${#B64} base64 chars)"

# --- keep it --------------------------------------------------------------
APP_ID="$APP_ID_ARG"
[ -z "$APP_ID" ] && APP_ID="$(grep '^ENABLE_BANKING_APP_ID=' "$ENV_FILE" | cut -d= -f2-)"

if [ -f "$REPO_ROOT/compose/config.json" ]; then
  FP="$REPO_ROOT/scripts/firefly-pocket"
  "$FP" config set --no-render ENABLE_BANKING_PRIVATE_KEY - <<<"$B64" >/dev/null
  [ -z "$APP_ID_ARG" ] || "$FP" config set --no-render ENABLE_BANKING_APP_ID "$APP_ID_ARG" >/dev/null
  "$FP" config render
  echo "==> settings updated"
else
python3 - "$B64" "$APP_ID" "$ENV_FILE" <<'PY'
import sys, pathlib
b64, app_id, env_path = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(env_path)
out = []
for line in p.read_text().splitlines():
    if line.startswith("ENABLE_BANKING_PRIVATE_KEY="):
        out.append("ENABLE_BANKING_PRIVATE_KEY=" + b64)
    elif line.startswith("ENABLE_BANKING_APP_ID=") and app_id:
        out.append("ENABLE_BANKING_APP_ID=" + app_id)
    else:
        out.append(line)
p.write_text("\n".join(out) + "\n")
PY
chmod 600 "$ENV_FILE"
echo "==> compose/.env updated"
fi

# --- ask Enable Banking what this application actually is ----------------
if [ -z "$APP_ID" ]; then
  echo "!! No application ID known; skipping the environment check." >&2
  exit 0
fi

# Signed and sent as the setup wizard and the console check it (bank.sh), with
# the key as the store now has it.
# shellcheck source=bank.sh
source "$REPO_ROOT/scripts/bank.sh"
eb_check "$B64" "$APP_ID" || true
HTTP_CODE="$EB_STATUS"
APP_JSON="$EB_ANSWER"

# Surface the API's own error rather than reporting a useless "unknown".
# A 401 "Wrong signature" almost always means the key and the application ID
# belong to different applications — e.g. a new PEM was downloaded but the old
# ID is still in .env. Pass the new ID as the second argument.
if [ "$HTTP_CODE" != "200" ]; then
  echo "!! Enable Banking API returned HTTP $HTTP_CODE" >&2
  printf '%s' "$APP_JSON" | jq -r '"!! \(.code // "?"): \(.message // .)"' 2>/dev/null >&2 \
    || printf '!! %s\n' "$(printf '%s' "$APP_JSON" | head -c 200)" >&2
  if printf '%s' "$APP_JSON" | grep -qi 'signature'; then
    cat >&2 <<EOF
!!
!! The key does not match application ID:
!!   $APP_ID
!! A newly created application has a NEW id. Re-run with it:
!!   $0 $PEM <new-application-id>
EOF
  fi
  echo
  echo "The private key WAS kept, but the application ID"
  echo "is unverified — fix the ID before deploying."
  exit 1
fi

ENVIRONMENT="$(printf '%s' "$APP_JSON" | jq -r '.environment // "unknown"' 2>/dev/null)"
NAME="$(printf '%s' "$APP_JSON" | jq -r '.name // "unknown"' 2>/dev/null)"

echo "==> application : $NAME"
echo "==> environment : $ENVIRONMENT"
printf '%s' "$APP_JSON" | jq -r '.redirect_urls[]? | "==> redirect    : \(.)"' 2>/dev/null
# Both callbacks must be registered, exactly: a link started from Firefly Pocket
# comes back to its host, one from the importer's UI to the importer's.
HOSTS="$(set +eu; source "$REPO_ROOT/scripts/lib.sh" >/dev/null 2>&1 && printf '%s %s' "$NEXT_HOSTNAME" "$IMPORT_HOSTNAME")" || HOSTS=""
for host in $HOSTS; do
  if ! printf '%s' "$APP_JSON" | jq -e --arg u "https://$host/eb-callback" '(.redirect_urls // []) | index($u)' >/dev/null 2>&1; then
    echo "==> WARNING     : https://$host/eb-callback is not a redirect URL of this application; add it in the control panel"
  fi
done
printf '%s' "$APP_JSON" | jq -r 'if (.services // []) | index("PIS") then "==> WARNING     : app requests PIS (payment initiation) — not needed by Firefly Pocket" else "==> services    : \(.services // [] | join(", "))" end' 2>/dev/null

if [ "$ENVIRONMENT" = "SANDBOX" ]; then
  cat <<'EOF'

  ------------------------------------------------------------------
  WARNING: this is a SANDBOX application.

  It can only ever reach the "Mock ASPSP" simulator. Real banks are
  not present in the sandbox catalogue at all, so the importer will
  show no usable bank and give no reason why.

  For real accounts you need a PRODUCTION application, activated in
  restricted mode by linking your own accounts in the Enable Banking
  control panel (free for personal use). A new application means a
  new ID and a new PEM — re-run this script with both, and register
  both redirect URLs on it (README "Connect your bank"; or let
  scripts/firefly-pocket setup bank make the key and certificate):
  https://app.<DOMAIN>/eb-callback and https://import.<DOMAIN>/eb-callback.
  ------------------------------------------------------------------
EOF
fi

# The setup wizard starts the stack itself afterwards.
[ -z "${FROM_SETUP:-}" ] || exit 0
echo
echo "Next: recreate the importer:"
echo "  docker compose up -d --force-recreate importer"
