#!/usr/bin/env bash
#
# Nightly backup: dump every database, archive Firefly III's attachments, then
# push everything offsite with restic.
#
# Three layers, because a backup sitting on the same disk as the data is not a
# backup. Local dumps cover "I broke something an hour ago", restic covers
# "the machine is gone", and the weekly Hetzner snapshot (configured out of
# band) covers "I want the whole box back".
#
# Verify it actually works with scripts/restore-test.sh. An untested backup is
# a hope, not a plan.

set -uo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

BACKUP_DIR="${BACKUP_DIR:-/var/backups/fireflyx}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOCAL_KEEP_DAYS=3

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

fail() {
  notify "Firefly Pocket: BACKUP FAILED" "$1"
  healthcheck_ping "${HEALTHCHECK_BACKUP_URL:-}" fail "$1"
  exit 1
}

dc() {
  docker compose --project-directory "$COMPOSE_DIR" "$@"
}

# --- 0. Fingerprint --------------------------------------------------------
# What the dumps below hold, as row counts: restore-test.sh checks the restored
# copy against it. Taken first, under the lock the cron jobs share, so no
# import runs in between. A backup without one is still a backup, so a failure
# here only warns.
echo "==> fingerprint"
if ! "$REPO_ROOT/scripts/fingerprint.sh" > "$BACKUP_DIR/fingerprint-${STAMP}.txt"; then
  rm -f "$BACKUP_DIR/fingerprint-${STAMP}.txt"
  notify "Firefly Pocket: backup has no fingerprint" \
    "scripts/fingerprint.sh failed, so tonight's restore test cannot compare row counts. The backup itself goes on."
fi

# --- 1. Databases ----------------------------------------------------------
# Custom format (-Fc): compressed, and restorable table-by-table if you ever
# need to cherry-pick rather than restore wholesale.
for db in firefly firefly_pico fireflyx_importer firefly_next; do
  # Firefly Pocket's database stays empty until its first image has started and
  # migrated it (README "Adding Firefly Pocket"), and an empty dump would fail the
  # size check below, and with it the whole backup. Until then there is
  # nothing in it to keep.
  if [ "$db" = firefly_next ] && [ "$(dc exec -T -e PGPASSWORD="$POSTGRES_SUPER_PASSWORD" db \
        psql -U postgres -d "$db" -tAc "SELECT to_regclass('public.migrations') IS NOT NULL" 2>/dev/null \
        | tr -d '[:space:]')" != t ]; then
    echo "==> skipping ${db}: not created or not migrated yet"
    continue
  fi
  out="$BACKUP_DIR/${db}-${STAMP}.dump"
  echo "==> dumping ${db}"
  if ! dc exec -T -e PGPASSWORD="$POSTGRES_SUPER_PASSWORD" db \
        pg_dump -U postgres -Fc "$db" > "$out"; then
    rm -f "$out"
    fail "pg_dump of ${db} failed"
  fi
  # A dump small enough to be empty means something went wrong silently.
  if [ ! -s "$out" ] || [ "$(stat -c %s "$out" 2>/dev/null || stat -f %z "$out")" -lt 1024 ]; then
    fail "dump of ${db} is suspiciously small — treating as failure"
  fi
done

# --- 2. Attachments --------------------------------------------------------
# Receipts and documents attached to transactions live in a Docker volume,
# not in Postgres, so they need archiving separately.
echo "==> archiving attachments"
if ! docker run --rm \
      -v fireflyx_firefly_upload:/data:ro \
      -v "$BACKUP_DIR":/backup \
      alpine:3.21 \
      tar czf "/backup/uploads-${STAMP}.tar.gz" -C /data . ; then
  fail "attachment archive failed"
fi

# --- 3. Configuration ------------------------------------------------------
# .env holds every secret, including IMPORTER_APP_KEY, without which the bank
# sessions in the fireflyx_importer dump cannot be decrypted. config/importers/
# holds the hand-exported configs from before the importer fork took over; it
# is kept until no longer needed (gitignored, so it exists only here).
cp "$ENV_FILE" "$BACKUP_DIR/env-${STAMP}.bak"
if ls "$REPO_ROOT"/config/importers/*.json >/dev/null 2>&1; then
  tar czf "$BACKUP_DIR/importers-${STAMP}.tar.gz" -C "$REPO_ROOT" \
    --exclude='config/importers/.backup' config/importers \
    || fail "importer config archive failed"
fi

# --- 4. Offsite ------------------------------------------------------------
OFFSITE=1
if [ -z "${RESTIC_REPOSITORY:-}" ]; then
  OFFSITE=0
  notify "Firefly Pocket: backup local-only" \
    "RESTIC_REPOSITORY is not set, so tonight's backup exists only on this machine. Set it in .env."
else
  echo "==> pushing to restic repository"
  # First run needs an initialised repo; `cat` keeps a benign "already
  # initialized" from tripping the error path.
  restic snapshots >/dev/null 2>&1 || restic init || fail "restic init failed"

  restic backup --tag fireflyx "$BACKUP_DIR" || fail "restic backup failed"

  restic forget --tag fireflyx \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
    --prune || notify "Firefly Pocket: restic prune failed" "Backup succeeded but retention pruning did not."
fi

# --- 5. Local retention ----------------------------------------------------
find "$BACKUP_DIR" -maxdepth 1 -type f -mtime "+${LOCAL_KEEP_DAYS}" -delete

# A backup on the same disk as the data is not a backup, so a local-only night
# reports as failed: the dead man's switch keeps saying so until restic is set.
if [ "$OFFSITE" -eq 1 ]; then
  healthcheck_ping "${HEALTHCHECK_BACKUP_URL:-}"
else
  healthcheck_ping "${HEALTHCHECK_BACKUP_URL:-}" fail \
    "local-only: RESTIC_REPOSITORY is not set, so the backup exists only on this machine"
fi

echo "backup completed: ${STAMP}"
