#!/usr/bin/env bash
#
# Proves the backups are restorable, without touching the live stack.
#
# Restores the most recent dump of every database (Firefly III, Pico and the
# importer's bank connections) into a throwaway Postgres container and checks
# their tables, lists the attachments archive end to end, compares row counts
# with the fingerprint taken at backup time, and checks that the .env copy
# holds IMPORTER_APP_KEY, without which the bank sessions in the
# importer dump cannot be decrypted. Everything is torn down afterwards; the
# running system is never modified.
#
# Run this once immediately after setup, while there is nothing to lose, and
# then periodically. A backup you have never restored is not yet a backup.
#
#   ./restore-test.sh              # test the newest local backup
#   ./restore-test.sh --from-restic  # pull the newest offsite snapshot first

set -uo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/fireflyx}"
SCRATCH="$(mktemp -d)"
CONTAINER="firefly-pocket-restore-test-$$"
TEST_PASSWORD="restoretest"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

SOURCE_DIR="$BACKUP_DIR"
WHERE="local"

if [ "${1:-}" = "--from-restic" ]; then
  [ -n "${RESTIC_REPOSITORY:-}" ] || { echo "RESTIC_REPOSITORY is not set." >&2; exit 1; }
  WHERE="offsite"
  echo "==> restoring newest offsite snapshot to scratch space"
  restic restore latest --tag fireflyx --target "$SCRATCH" || {
    echo "FAIL: could not restore from restic." >&2
    notify "Firefly Pocket: RESTORE TEST FAILED" "Could not restore the newest offsite (restic) snapshot."
    exit 1; }
  SOURCE_DIR="$(dirname "$(find "$SCRATCH" -name 'firefly-*.dump' | sort | tail -1)")"
fi

# newest <glob>: the newest file in SOURCE_DIR matching it, or nothing.
# The stamp in every name sorts by time. `firefly-*` does not match the
# `firefly_pico-*` dumps: the character after "firefly" differs.
newest() {
  find "$SOURCE_DIR" -maxdepth 1 -name "$1" | sort | tail -1
}

# Throwaway instance on no network, random host port, nothing persisted.
echo "==> starting scratch Postgres"
docker run -d --name "$CONTAINER" \
  -e POSTGRES_PASSWORD="$TEST_PASSWORD" \
  -e POSTGRES_DB=restoretest \
  postgres:17.11-alpine >/dev/null || { echo "FAIL: could not start Postgres." >&2; exit 1; }

echo -n "==> waiting for it to accept connections"
for _ in $(seq 1 30); do
  if docker exec "$CONTAINER" pg_isready -U postgres -d restoretest >/dev/null 2>&1; then
    echo " ok"; break
  fi
  echo -n "."; sleep 2
done

query() {
  docker exec "$CONTAINER" psql -U postgres -d "$1" -tAc "$2" 2>/dev/null | tr -d '[:space:]'
}

FAILED=0

# check_dump <database> "<required tables>" "<other tables>"
#
# Restores the newest dump of <database> into a database of the same name.
# Every required table must exist and have rows. The other tables are printed
# for a look but may be empty: Pico can have no templates and the importer no
# bank connection, and that is not a broken backup. For those two the
# `migrations` table is what proves the schema came back.
check_dump() {
  local db="$1" required="$2" others="$3" dump count table
  dump="$(newest "${db}-*.dump")"
  if [ -z "$dump" ]; then
    echo "    ${db}: no ${db}-*.dump in ${SOURCE_DIR}"
    FAILED=1
    return
  fi
  echo "==> ${db}: $(basename "$dump")  ($(du -h "$dump" | cut -f1))"
  docker exec "$CONTAINER" createdb -U postgres "$db"
  # --no-owner: the app roles do not exist in this scratch instance.
  # pg_restore warns about that harmlessly, so judge success by the row counts
  # below rather than by its exit status.
  docker exec -i "$CONTAINER" \
    pg_restore -U postgres -d "$db" --no-owner --no-privileges \
    < "$dump" 2>"$SCRATCH/restore-${db}.log"

  local bad=0
  for table in $required; do
    count="$(query "$db" "SELECT count(*) FROM ${table};")"
    if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
      printf '    %-30s %s rows\n' "$table" "$count"
    else
      printf '    %-30s MISSING OR EMPTY\n' "$table"
      bad=1
    fi
  done
  for table in $others; do
    count="$(query "$db" "SELECT count(*) FROM ${table};")"
    if [[ "$count" =~ ^[0-9]+$ ]]; then
      printf '    %-30s %s rows (may be empty)\n' "$table" "$count"
    else
      printf '    %-30s missing (may be empty)\n' "$table"
    fi
  done

  if [ "$bad" -ne 0 ]; then
    FAILED=1
    echo "    pg_restore log for ${db}:" >&2
    tail -20 "$SCRATCH/restore-${db}.log" >&2
  fi
}

echo "==> testing the ${WHERE} backup in ${SOURCE_DIR}"
check_dump firefly "users accounts transaction_journals" ""
check_dump firefly_pico "migrations" "profiles transaction_templates push_subscriptions"
check_dump fireflyx_importer "migrations" "fireflyx_connections fireflyx_connection_accounts fireflyx_import_runs"
# The backup leaves Firefly Pocket's database out until it has been migrated.
if [ -n "$(newest 'firefly_next-*.dump')" ]; then
  check_dump firefly_next "migrations" "profiles transaction_templates push_subscriptions"
else
  echo "    firefly_next: no dump yet (Firefly Pocket has not migrated its database)"
fi

# Attachments: listing the whole archive reads and decompresses every byte.
UPLOADS="$(newest 'uploads-*.tar.gz')"
if [ -z "$UPLOADS" ]; then
  echo "    attachments: no uploads-*.tar.gz in ${SOURCE_DIR}"
  FAILED=1
elif tar tzf "$UPLOADS" > "$SCRATCH/uploads.list" 2>/dev/null; then
  echo "==> attachments: $(basename "$UPLOADS") reads cleanly ($(wc -l < "$SCRATCH/uploads.list" | tr -d ' ') entries)"
else
  echo "    attachments: $(basename "$UPLOADS") is unreadable"
  FAILED=1
fi

# The fingerprint backup.sh took just before these dumps: the restored copy
# must hold the same rows and attachment files. The one with the same stamp as
# the Firefly III dump, so a later run that failed half-way cannot be compared
# with an older dump. Backups from before fingerprints existed have none.
STAMP_OF_DUMP="$(basename "$(newest 'firefly-*.dump')" .dump)"
RECORDED="$SOURCE_DIR/fingerprint-${STAMP_OF_DUMP#firefly-}.txt"
if [ ! -f "$RECORDED" ]; then
  echo "    fingerprint: none for this backup (taken before fingerprints existed)"
elif "$REPO_ROOT/scripts/fingerprint.sh" --container "$CONTAINER" --password "$TEST_PASSWORD" \
       ${UPLOADS:+--uploads-tar "$UPLOADS"} > "$SCRATCH/fingerprint.txt" \
     && diff "$RECORDED" "$SCRATCH/fingerprint.txt" > "$SCRATCH/fingerprint.diff"; then
  echo "==> fingerprint: the restored copy matches $(basename "$RECORDED") ($(wc -l < "$RECORDED" | tr -d ' ') values)"
else
  echo "    fingerprint: the restored copy differs from $(basename "$RECORDED") (< recorded, > restored):"
  sed 's/^/      /' "$SCRATCH/fingerprint.diff"
  FAILED=1
fi

# The .env copy. Without IMPORTER_APP_KEY the restored bank sessions are
# ciphertext, and every bank would have to be linked again. Its value is never
# printed.
ENV_COPY="$(newest 'env-*.bak')"
if [ -n "$ENV_COPY" ] && grep -qE '^IMPORTER_APP_KEY=.+' "$ENV_COPY"; then
  echo "==> .env copy: $(basename "$ENV_COPY") holds IMPORTER_APP_KEY"
else
  echo "    .env copy: missing, or has no IMPORTER_APP_KEY"
  FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "RESTORE TEST FAILED — your backups are not trustworthy." >&2
  notify "Firefly Pocket: RESTORE TEST FAILED" "The newest ${WHERE} backup did not restore cleanly."
  exit 1
fi

echo
echo "RESTORE TEST PASSED — every dump restores, the attachments archive reads, the row counts match the fingerprint (if the backup has one), the .env copy is complete."
