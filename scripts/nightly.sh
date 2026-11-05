#!/usr/bin/env bash
#
# The nightly maintenance run. One cron entry, executed in order.
#
# Deliberately sequential rather than separate cron entries at guessed offsets:
# the import configs must be rendered *before* the import reads them, the
# import report must run *after* the import has finished, and the category
# suggestions after that. If an import ever runs long, the ordering holds.
#
# A failing step alerts and does not stop the remaining steps — a bank import
# failure should not also skip Firefly III's own maintenance.

set -uo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

FAILURES=0
NIGHTLY_LOG=/var/log/fireflyx/nightly.log

# Bank connections live in the importer fork's database (docs/design/bank-link.md).
# The importer logs at debug level to stdout, interleaved with the commands'
# own one-line-per-connection summaries; drop the DEBUG/INFO/NOTICE log lines
# so an alert shows the summary (and any real error), not the noise. The
# command's exit code, not grep's, is what the step returns.
importer_artisan() {
  docker compose --project-directory "$COMPOSE_DIR" exec -T importer php artisan "$@" 2>&1 \
    | { grep -vE '^\[[0-9-]+ [0-9:]+\] [a-z]+\.(DEBUG|INFO|NOTICE):' || true; }
  return "${PIPESTATUS[0]}"
}

# --- 1. Consent check ------------------------------------------------------
# Asks Enable Banking for every connection's consent status and expiry. Fails
# (and so alerts) when a consent has ended, or on the days it is 14, 7 and 3
# days from ending, so there is time to re-authenticate before imports stop.
run_step "bank consent check" \
  importer_artisan fireflyx:connections:refresh \
  || FAILURES=$((FAILURES + 1))

# --- 2. Render the import configs -----------------------------------------
# Writes the shared base config + each usable connection + one date window
# (today minus IMPORT_LOOKBACK_DAYS) into /import, and removes the files of
# connections that are gone, expired or unmapped. A connection saved in
# Firefly Pocket during the day is therefore imported tonight, with no deploy or restart.
# If the base config is invalid, nothing is written: yesterday's files stay.
run_step "render import configs" \
  importer_artisan fireflyx:render \
  || FAILURES=$((FAILURES + 1))

# --- 3. Pull new transactions from the banks ------------------------------
# Called on the internal network, so it never touches Caddy's basic auth.
#
# One call imports EVERY config in /import, sequentially, inside this one
# request — so the timeout below is the ceiling for all of them combined, not
# per bank. Raise it if you add enough connections to approach it. Each config
# is wrapped in its own try/catch upstream, so one expired consent does not
# stop the others; the log check below is what surfaces the one that failed.
#
# Two things this call gets wrong easily, both of which fail silently-ish:
#
#   POST, not GET  — the route is Route::post('/autoimport', ...). A GET is
#   answered with a bare 405 that never reaches application code, so the log
#   check below stays clean while nothing at all has been imported.
#
#   directory=/import is REQUIRED — omit it and the controller falls back to
#   realpath('./'), the container's working directory, which is not in
#   IMPORT_DIR_ALLOWLIST: "Not allowed to import from this path."
IMPORT_STARTED="$(date -Is)"
IMPORT_CALL_OK=1
IMPORT_CHECK_OK=1
log_step "bank import" \
  internal_http_post "http://importer:8080/autoimport?secret=${AUTO_IMPORT_SECRET}&directory=/import" 1800 \
  || IMPORT_CALL_OK=0

# The call above returns 200 even when the import itself failed, so ask the
# importer's log whether it really worked.
log_step "bank import error check" \
  check_importer_errors "$IMPORT_STARTED" \
  || IMPORT_CHECK_OK=0

# --- 4. Per-connection import report ---------------------------------------
# The importer records each connection's result from this run, and writes the
# notification for it: "<account> import succeeded" with how many transactions
# came in, or what went wrong, what to do about it and where the exact error is.
# A connection that was rendered but not imported at all is reported as a
# failure too — the check that a new connection really did start importing.
# Which of these reach the phone is each device's setting in Pocket.
#
# The three steps above do not alert on their own any more: their output is in
# this log, and what the user is told comes from here.
import_report() {
  # The importer's own log lines share stdout with the JSON; it is the array.
  docker compose --project-directory "$COMPOSE_DIR" exec -T importer \
    php artisan fireflyx:connections:report --since="$1" --json 2>/dev/null \
    | awk '/^\[\]?$/ { p = 1 } p { print } /^\]$|^\[\]$/ { exit }'
  return "${PIPESTATUS[0]}"
}

echo "==> bank import report"
REPORT="$(import_report "$IMPORT_STARTED")"
printf '%s\n' "$REPORT" | jq -r '.[]? | "\(.name): \(.notice.event), \(.summary // "not imported" | tostring)"' 2>/dev/null || true
notify_import_results "$REPORT"
case $? in
  0)
    # Every connection imported cleanly. If the log still held something
    # unexpected, say so rather than let it pass.
    if [ "$IMPORT_CHECK_OK" -eq 0 ] || [ "$IMPORT_CALL_OK" -eq 0 ]; then
      notify_event import.failure "Bank import needs a look" \
        "Every bank reported success, but the importer logged something unexpected. Exact error: ${NIGHTLY_LOG}." /bank-connections
      FAILURES=$((FAILURES + 1))
    fi
    ;;
  1) FAILURES=$((FAILURES + 1)) ;;
  *)
    notify_event import.failure "Bank import could not be checked" \
      "The importer did not answer, so it is not known whether last night's import worked. Check that it is running. Exact error: ${NIGHTLY_LOG}." /bank-connections
    FAILURES=$((FAILURES + 1))
    ;;
esac

# --- 5. Category suggestions ----------------------------------------------
# The Categorization rules already ran on every imported transaction. For what
# is still uncategorized, the suggester writes INACTIVE rules into the
# `Suggestions` group for review in Firefly Pocket. It never sets a category itself.
# It exits non-zero only when Firefly or the model API is unreachable.
run_step "category suggestions" \
  docker compose --project-directory "$COMPOSE_DIR" \
    run --rm --no-deps suggester suggest \
  || FAILURES=$((FAILURES + 1))

# --- 6. Firefly III's own maintenance -------------------------------------
# Fires recurring transactions and bill notifications. Easy to forget, and
# without it recurring transactions silently never happen.
run_step "Firefly III cron" \
  internal_http "http://app:8080/api/v1/cron/${STATIC_CRON_TOKEN}" 300 \
  || FAILURES=$((FAILURES + 1))

if [ "$FAILURES" -gt 0 ]; then
  echo "nightly run finished with ${FAILURES} failed step(s)" >&2
  healthcheck_ping "${HEALTHCHECK_NIGHTLY_URL:-}" fail \
    "nightly run finished with ${FAILURES} failed step(s); see ${NIGHTLY_LOG}"
  exit 1
fi

healthcheck_ping "${HEALTHCHECK_NIGHTLY_URL:-}"
echo "nightly run completed cleanly"
