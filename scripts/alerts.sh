# shellcheck shell=bash
# Alerts: an ntfy topic, and healthchecks.io's two checks, the dead man's
# switch, made with its API key. For the setup wizard's alerts step (setup.sh)
# and the console's (console.sh), so both do it the same way. Sourced after
# lib.sh (TZ); uses curl and jq. A topic URL, a ping URL and an API key go to
# curl on stdin, never on its command line.

# Where the checks are made. Another only in the boot test, which answers it itself.
HEALTHCHECKS_API="${HEALTHCHECKS_API:-https://healthchecks.io}"

# The schedules, in TZ: as the crontab runs the jobs.
HC_NIGHTLY_NAME="Firefly Pocket nightly"
HC_NIGHTLY_SCHEDULE="0 3 * * *"
HC_BACKUP_NAME="Firefly Pocket backup"
HC_BACKUP_SCHEDULE="0 2 * * *"

# curl_url <url> <curl args...>: curl with its URL on stdin.
curl_url() {
  local url="${1//\\/\\\\}"
  shift
  printf 'url = "%s"\n' "${url//\"/\\\"}" | curl --config - "$@"
}

# ntfy_send <url> <title> <message>: 0 when ntfy took it.
ntfy_send() {
  curl_url "$1" -fsS --max-time 20 -o /dev/null -H "Title: $2" -d "$3" 2>/dev/null
}

# hc_check <api-key> <name> <cron> <what>: the healthchecks.io check of that
# name, made or found, with that schedule in TZ. Its ping URL in HC_URL; on a
# failure, HC_PROBLEM says why.
hc_check() {
  local body payload code said
  HC_URL=""
  body="$(mktemp)"
  payload="$(jq -cn --arg name "$2" --arg schedule "$3" --arg tz "${TZ:-Etc/UTC}" --arg desc "$4" \
    '{name: $name, schedule: $schedule, tz: $tz, grace: 3600, channels: "*", unique: ["name"], tags: "firefly-pocket", desc: $desc}')"
  code="$(printf 'header = "X-Api-Key: %s"\n' "$1" | curl -sS --max-time 30 --config - -H 'Content-Type: application/json' \
    --data "$payload" -o "$body" -w '%{http_code}' "$HEALTHCHECKS_API/api/v3/checks/" 2>/dev/null || true)"
  code="${code:-000}"
  if [ "$code" = 200 ] || [ "$code" = 201 ]; then
    HC_URL="$(jq -r '.ping_url // empty' "$body" 2>/dev/null || true)"
    rm -f "$body"
    [ -z "$HC_URL" ] || return 0
    HC_PROBLEM="healthchecks.io made the check but gave no ping URL."
    return 1
  fi
  said="$(jq -r '.error // empty | tostring' "$body" 2>/dev/null | tr -d '\000-\037\177' | cut -c1-200 || true)"
  rm -f "$body"
  # shellcheck disable=SC2034  # HC_PROBLEM is the caller's
  case "$code" in
    000) HC_PROBLEM="healthchecks.io did not answer. Try again in a minute." ;;
    401) HC_PROBLEM="healthchecks.io does not take this API key (HTTP 401${said:+: $said}): it is the project's read-write key, under Settings, API Access." ;;
    *) HC_PROBLEM="healthchecks.io answered HTTP $code${said:+: $said}." ;;
  esac
  return 1
}

# hc_setup <api-key>: both checks, the nightly import's and the backup's. Their
# ping URLs in HC_NIGHTLY and HC_BACKUP.
hc_setup() {
  local host
  host="$(hostname)"
  hc_check "$1" "$HC_NIGHTLY_NAME" "$HC_NIGHTLY_SCHEDULE" "scripts/nightly.sh on $host: the bank import" || return 1
  # shellcheck disable=SC2034  # HC_NIGHTLY and HC_BACKUP are the caller's
  HC_NIGHTLY="$HC_URL"
  hc_check "$1" "$HC_BACKUP_NAME" "$HC_BACKUP_SCHEDULE" "scripts/backup.sh on $host" || return 1
  # shellcheck disable=SC2034
  HC_BACKUP="$HC_URL"
}

# hc_ping <url> <message>: one ping, so the check starts out up.
hc_ping() {
  curl_url "$1" -fsS --max-time 10 -o /dev/null --data-raw "$2" 2>/dev/null
}
