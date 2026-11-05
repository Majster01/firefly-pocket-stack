#!/usr/bin/env bash
#
# Prints a fingerprint of the data: row counts of the tables that hold it, the
# date of the newest transaction, and how many attachment files there are. One
# `name value` line each, sorted, so two fingerprints compare with diff.
#
# Taken before and after any change to the server, it shows that nothing was
# lost. backup.sh stores one with every backup, and restore-test.sh checks the
# restored copy against it.
#
#   ./fingerprint.sh > before.txt         # the live stack
#   ...change something...
#   diff before.txt <(./fingerprint.sh)   # only the night's new rows may differ
#
# restore-test.sh points it at its scratch instance instead:
#
#   ./fingerprint.sh --container <name> --password <pw> --uploads-tar <file>
#
# A database without a `migrations` table is left out, as backup.sh leaves out
# Firefly Pocket's before its first migration. A missing table prints `missing`.
set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

CONTAINER="fireflyx-db"
PASSWORD="${POSTGRES_SUPER_PASSWORD:-}"
UPLOADS_TAR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --container)   CONTAINER="$2"; shift 2 ;;
    --password)    PASSWORD="$2"; shift 2 ;;
    --uploads-tar) UPLOADS_TAR="$2"; shift 2 ;;
    *) echo "usage: $0 [--container <name>] [--password <pw>] [--uploads-tar <file>]" >&2; exit 2 ;;
  esac
done

# The tables that hold what a person entered or the bank sent. Caches, sessions,
# jobs and pending consents are left out: they change on their own, and losing
# them loses nothing.
tables_of() {
  case "$1" in
    firefly)           echo "users accounts transaction_journals transactions attachments rules rule_groups budgets categories tags bills piggy_banks recurrences" ;;
    fireflyx_importer) echo "fireflyx_connections fireflyx_connection_accounts fireflyx_import_runs fireflyx_connection_events fireflyx_manual_imports" ;;
    firefly_next)      echo "profiles transaction_templates transaction_template_tags tags accounts categories budgets piggy_banks recurrences push_subscriptions assistant_rambles" ;;
    firefly_pico)      echo "profiles transaction_templates push_subscriptions" ;;
  esac
}

sql() {
  docker exec -e PGPASSWORD="$PASSWORD" "$CONTAINER" \
    psql -U postgres -d "$1" -v ON_ERROR_STOP=1 -tAc "$2" | tr -d '[:space:]'
}

# Every check below reads an empty answer as "not there", so first make sure
# the server answers at all: a fingerprint of an unreachable database would
# look like one whose data is gone.
if [ "$(sql postgres "SELECT 1" 2>/dev/null)" != 1 ]; then
  echo "FATAL: cannot query Postgres in container $CONTAINER." >&2
  exit 1
fi

{
  for db in firefly fireflyx_importer firefly_next firefly_pico; do
    [ "$(sql postgres "SELECT count(*) FROM pg_database WHERE datname = '$db'")" = 1 ] || continue
    [ "$(sql "$db" "SELECT to_regclass('public.migrations') IS NOT NULL")" = t ] || continue
    for table in $(tables_of "$db"); do
      if [ "$(sql "$db" "SELECT to_regclass('public.$table') IS NOT NULL")" = t ]; then
        echo "$db.$table $(sql "$db" "SELECT count(*) FROM $table")"
      else
        echo "$db.$table missing"
      fi
    done
    if [ "$db" = firefly ]; then
      newest="$(sql firefly "SELECT coalesce(to_char(max(date), 'YYYY-MM-DD'), 'none') FROM transaction_journals WHERE deleted_at IS NULL")"
      echo "firefly.newest_transaction $newest"
    fi
  done

  # Attachment files: in the live volume, or in a backup's archive.
  # The volume is checked first: `docker run -v` would create an empty one.
  if [ -n "$UPLOADS_TAR" ]; then
    echo "attachments.files $(tar tzvf "$UPLOADS_TAR" | grep -c '^-' || true)"
  elif ! docker volume inspect fireflyx_firefly_upload >/dev/null 2>&1; then
    echo "attachments.files missing"
  else
    echo "attachments.files $(docker run --rm -v fireflyx_firefly_upload:/data:ro alpine:3.21 \
      find /data -type f | wc -l | tr -d ' ')"
  fi
} | LC_ALL=C sort
