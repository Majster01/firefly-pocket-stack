# shellcheck shell=bash
# Shared helpers for the firefly-pocket-stack maintenance scripts.
# Sourced, not executed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$REPO_ROOT/compose"
ENV_FILE="$COMPOSE_DIR/.env"

# Small pinned image used to make HTTP calls on the internal Docker network,
# so automation never has to go out through Caddy (and therefore never has to
# get past the importer's basic auth).
CURL_IMAGE="curlimages/curl:8.21.0"
DOCKER_NETWORK="fireflyx"
# The console's network, which it shares with Caddy only (docker-compose.yml).
CONSOLE_NETWORK="fireflyx_console"

# The services whose new image migrates a database on start, so the deploy
# backs up and restore-tests before it starts one. The bundle's release.json
# says the same (scripts/make-bundle.sh reads this line).
# shellcheck disable=SC2034  # used by deploy.sh
MIGRATING="app db importer"

# What the release bundle holds: everything a server reads, and nothing it
# does not, so no CI, Terraform, docs or the suggester's source (its image is
# in the bundle by digest). The console's source is in it: compose runs it on
# the stock python image, mounted. scripts/make-bundle.sh reads this line to
# build the bundle, and the server agent's shadow mode to compare one with the
# checkout.
# shellcheck disable=SC2034  # read by make-bundle.sh and agent.sh, not sourced
BUNDLE_PATHS="LICENSE crontab host scripts config services/console compose/docker-compose.yml compose/Caddyfile compose/.env.example compose/initdb compose/legal compose/secrets compose/importer"

if [ ! -f "$ENV_FILE" ]; then
  echo "FATAL: $ENV_FILE not found. Run scripts/gen-secrets.sh first." >&2
  exit 1
fi

# Load .env without executing it. Only accepts KEY=VALUE lines with an
# uppercase key, so comments and stray text cannot run as code.
load_env() {
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    # Compose stores the bcrypt hash with `$` doubled; undo that for shell use.
    if [ "$key" = "IMPORT_AUTH_HASH" ]; then
      val="${val//\$\$/\$}"
    fi
    export "$key=$val"
  done < "$ENV_FILE"
}

load_env

# The hostnames as compose derives them (docker-compose.yml, the caddy
# service): <name>.DOMAIN unless .env sets one on its own, Pocket's being
# DOMAIN itself. Compose would make "iii." of a missing DOMAIN, so the deploy
# and the tests stop here instead.
export FIREFLY_HOSTNAME="${FIREFLY_HOSTNAME:-${DOMAIN:+iii.$DOMAIN}}"
export NEXT_HOSTNAME="${NEXT_HOSTNAME:-${DOMAIN:-}}"
export IMPORT_HOSTNAME="${IMPORT_HOSTNAME:-${DOMAIN:+import.$DOMAIN}}"
export LEGAL_HOSTNAME="${LEGAL_HOSTNAME:-${DOMAIN:+legal.$DOMAIN}}"
for _host in FIREFLY_HOSTNAME NEXT_HOSTNAME IMPORT_HOSTNAME LEGAL_HOSTNAME; do
  if [ -z "${!_host}" ]; then
    echo "FATAL: set DOMAIN in $ENV_FILE; $_host is not set either" >&2
    exit 1
  fi
done
unset _host
# The console's host. A server with no DOMAIN has none until ADMIN_HOSTNAME is
# set: Caddy then serves admin.localhost, from its own CA, which no one
# outside reaches by name.
export ADMIN_HOSTNAME="${ADMIN_HOSTNAME:-admin.${DOMAIN:-localhost}}"

# Firefly Pocket's Web Push endpoint, reached on the internal network (Caddy refuses
# /api/internal/* from outside). Only used when NEXT_NOTIFY_TOKEN is set.
NEXT_NOTIFY_URL="${NEXT_NOTIFY_URL:-http://next:80/api/internal/notify}"

# json_string <text> <max-chars>
#
# <text> as a JSON string literal, cut to <max-chars> (with a trailing "...").
# Firefly Pocket rejects a title over 100 or a body over 300 characters with a 422, and an
# alert that is too long to deliver is worse than one that is shortened. Control
# characters other than tab, newline and carriage return are dropped: the
# message can carry raw command output, escape sequences included.
json_string() {
  local s="$1" max="$2"
  s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
  if [ "${#s}" -gt "$max" ]; then
    s="${s:0:$((max - 3))}..."
    # Under a non-UTF-8 locale (cron) the cut can land inside a multibyte
    # character; drop what is left of it rather than send invalid UTF-8.
    s="$(printf '%s' "$s" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || printf '%s' "$s")"
  fi
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# commit_status <context> <rev> <state> <description>
#
# Optional: what the server did with a revision, as a commit status on GitHub,
# so the commit list shows it: deploy/server (deploy.sh) and agent/shadow
# (agent.sh). DEPLOY_STATUS_TOKEN in .env is a fine-grained token for this
# repository only, "Commit statuses: write". The token goes to curl on stdin,
# so it does not show in `ps`.
commit_status() {
  [ -n "${DEPLOY_STATUS_TOKEN:-}" ] || return 0
  local slug
  slug="$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
  printf 'header = "Authorization: Bearer %s"\n' "$DEPLOY_STATUS_TOKEN" \
    | curl -fsS --max-time 15 -o /dev/null --config - \
        -H 'Accept: application/vnd.github+json' \
        --data "{\"state\":\"$3\",\"context\":$(json_string "$1" 100),\"description\":$(json_string "$4" 140)}" \
        "https://api.github.com/repos/$slug/statuses/$2" \
    || echo "WARN: could not set the GitHub commit status $1" >&2
}

# notify_push <title> <message> [event] [path] [count]
#
# Web Push to the Firefly Pocket app, so the alert shows up as a native notification.
# Never fails and never writes anything but a WARN: ntfy, the log line and the
# step that raised the alert all matter more than this extra channel, and push
# is expected to be unavailable until Firefly Pocket has the receiver and VAPID keys (503).
#
# <event> says what kind of message this is (import.success, import.failure,
# suggestions.digest, upgrade.success); each device's notification settings in
# Firefly Pocket decide whether it gets it. Without one the message is an alert that
# every device gets. <count> is the number of new transactions of an import.
# <path> is the page a tap opens.
#
# The token goes to curl on stdin as a config file, not on the command line, so
# it does not show in `ps`.
notify_push() {
  local title="$1" message="$2" event="${3:-}" path="${4:-/}" count="${5:-}" body out code extra=""
  [ -n "$event" ] && extra=",\"event\":$(json_string "$event" 40)"
  [[ "$count" =~ ^[0-9]+$ ]] && extra="$extra,\"count\":$count"
  body="{\"title\":$(json_string "$title" 100),\"body\":$(json_string "$message" 300),\"path\":$(json_string "$path" 200)$extra}"
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$NEXT_NOTIFY_TOKEN" \
    | docker run --rm -i --network "$DOCKER_NETWORK" "$CURL_IMAGE" \
        --silent --max-time 20 --config - \
        --header 'Content-Type: application/json' \
        --request POST --data "$body" \
        --output /dev/null --write-out '%{http_code}' \
        "$NEXT_NOTIFY_URL" 2>/dev/null)" || out=""
  code="${out: -3}"
  if [ "$code" != "200" ]; then
    echo "WARN: Firefly Pocket push notification failed (HTTP ${code:-none})" >&2
  fi
  return 0
}

notify_ntfy() {
  [ -n "${NTFY_URL:-}" ] || return 0
  curl -fsS --max-time 20 \
    -H "Title: $1" \
    -d "$2" \
    "$NTFY_URL" >/dev/null 2>&1 || echo "WARN: ntfy notification failed" >&2
}

# notify <title> <message>
#
# An alert: something went wrong or needs attention. Sends a push via ntfy if
# NTFY_URL is set, and to the Firefly Pocket app if NEXT_NOTIFY_TOKEN is set; always logs
# to stderr. Each channel is independent: one failing only logs a WARN and the
# others still go out. Every device gets an alert whatever its notification
# settings say.
# A silent failure is this system's most likely failure mode — the bank
# consent expires, imports quietly stop, and nothing looks broken. Alerting
# is what turns that into something you find out about.
notify() {
  local title="$1" message="$2"
  echo "[$(date -Is)] ${title}: ${message}" >&2
  notify_ntfy "$title" "$message"
  if [ -n "${NEXT_NOTIFY_TOKEN:-}" ]; then
    notify_push "$title" "$message"
  fi
}

# notify_event <event> <title> <message> [path] [count]
#
# A message the user chose to get (see notify_push for the events): a finished
# import, an upgrade, the suggestions digest. It goes to the Firefly Pocket app, where
# each device's settings decide who receives it; ntfy only gets what went wrong
# (import.failure), as the channel that does not depend on Firefly Pocket.
notify_event() {
  local event="$1" title="$2" message="$3" path="${4:-/}" count="${5:-}"
  echo "[$(date -Is)] ${title}: ${message}" >&2
  if [ "$event" = import.failure ]; then
    notify_ntfy "$title" "$message"
  fi
  if [ -n "${NEXT_NOTIFY_TOKEN:-}" ]; then
    notify_push "$title" "$message" "$event" "$path" "$count"
  fi
}

# notify_import_results <report-json>
#
# <report-json> is `fireflyx:connections:report --json`: one row per connection
# with the notification the importer wrote for it (account and transaction count
# on success; what went wrong, what to do and where the exact error is on a
# failure). Sends each one. Returns 0 when every connection imported, 1 when at
# least one did not, 2 when <report-json> is not a report with notifications
# (the importer did not answer, or is still a version that does not write them).
notify_import_results() {
  local json="$1" event title body path count failed=0
  jq -e 'type == "array" and all(.[]; .notice.event != null)' >/dev/null 2>&1 <<<"$json" || return 2
  while IFS=$'\t' read -r event title body path count; do
    [ -n "$event" ] || continue
    [ "$event" = import.failure ] && failed=$((failed + 1))
    notify_event "$event" "$title" "$body" "$path" "$count"
  done < <(jq -r '.[] | .notice | [.event, .title, .body, .path, (.count // "")] | @tsv' <<<"$json")
  [ "$failed" -eq 0 ]
}

# compose_images <rev>: "<service> <image>" for every service of compose/docker-compose.yml at <rev>.
compose_images() {
  git -C "$REPO_ROOT" show "$1:compose/docker-compose.yml" 2>/dev/null | awk '
    /^services:/ { in_services = 1; next }
    in_services && /^[^ #]/ { in_services = 0 }
    in_services && /^  [a-z][a-z0-9_-]*:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); next }
    in_services && svc != "" && /^    image:[[:space:]]/ { print svc, $2 }'
}

# package_label <service>
package_label() {
  case "$1" in
    app) echo "Firefly III" ;;
    db) echo "Postgres" ;;
    caddy) echo "Caddy" ;;
    next) echo "Firefly Pocket" ;;
    importer) echo "Data importer" ;;
    dozzle) echo "Dozzle" ;;
    socket-proxy) echo "Docker socket proxy" ;;
    suggester) echo "Category suggester" ;;
    *) echo "$1" ;;
  esac
}

# package_version <image>: the release in the tag (6.6.6, 17.11, 2.3.5), or nothing
# for a tag that is only a commit (sha-93eac8c).
package_version() {
  local ref="${1%@sha256:*}"   # a bundle pins tag@digest; the tag is what says the version
  local tag="${ref##*:}"
  [ "$tag" != "$ref" ] || return 0
  tag="${tag#version-}"; tag="${tag#v}"; tag="${tag%-alpine}"
  [[ "$tag" =~ ^[0-9]+(\.[0-9]+)*$ ]] && { echo "$tag"; return 0; }
  # <release>-<commit>, as the importer fork is tagged
  [[ "$tag" =~ ^([0-9]+(\.[0-9]+)*)-[0-9a-f]{7,}$ ]] && echo "${BASH_REMATCH[1]}"
  return 0
}

# upgraded_packages <old-rev> <new-rev>
#
# One line per package whose image changed between the two revisions, as a
# person would say it: "Firefly III 6.6.6 → 6.7.0", or just "Firefly Pocket"
# when only a build changed. Nothing when no package changed.
upgraded_packages() {
  local old="$1" new="$2" old_images new_images svc image previous label from to
  [ -n "$old" ] && [ -n "$new" ] || return 0
  old_images="$(compose_images "$old")"
  new_images="$(compose_images "$new")"
  while read -r svc image; do
    [ -n "$svc" ] || continue
    previous="$(awk -v s="$svc" '$1 == s { print $2 }' <<<"$old_images")"
    # A service that is new is not an upgrade, one whose tag is the same is not either
    { [ -n "$previous" ] && [ "$previous" != "$image" ]; } || continue
    label="$(package_label "$svc")"
    from="$(package_version "$previous")"
    to="$(package_version "$image")"
    if [ -n "$from" ] && [ -n "$to" ] && [ "$from" != "$to" ]; then
      echo "$label $from → $to"
    else
      echo "$label"
    fi
  done <<<"$new_images"
  return 0
}

# healthcheck_ping <url> [fail] [message]
#
# A dead man's switch. Every alert above is sent FROM this machine, so when the
# machine is down, or cron has stopped, nothing alerts at all. A ping to an
# outside service (healthchecks.io, or anything with its URL scheme) at the end
# of each run turns that silence into an alert: the service warns you when a
# ping does not arrive on schedule. `fail` reports a run that finished but
# failed, with <message> as the ping body (shown in the service's alert), so
# keep transaction data out of it. An empty <url> does nothing, and a failed
# ping only logs a WARN.
healthcheck_ping() {
  local url="$1" suffix="${2:+/$2}" message="${3:-}"
  [ -n "$url" ] || return 0
  curl -fsS --max-time 10 --retry 3 -o /dev/null \
    --data-raw "$(printf '%s' "$message" | head -c 2000)" \
    "${url}${suffix}" \
    || echo "WARN: healthcheck ping failed" >&2
  return 0
}

# Run an HTTP call against a container on the internal network.
# internal_http <url> [max-seconds]
internal_http() {
  local url="$1" timeout="${2:-900}"
  docker run --rm --network "$DOCKER_NETWORK" "$CURL_IMAGE" \
    --fail --silent --show-error --location --max-time "$timeout" "$url"
}

# smoke_test: the apps answer on the internal network (Firefly III may still be
# migrating, so each gets five minutes), every service compose starts runs,
# and the console answers on its own network.
# Firefly Pocket's /api/test is a plain Laravel route: nginx, php-fpm and the
# app, no Firefly call and no login. The deploy's last step, and what CI checks
# a booted stack with (scripts/boot-test.sh).
# token_check <token>: a Firefly III token works, at Firefly III's API and
# through Firefly Pocket's, which forwards it to Firefly III on this network.
# The boot and upgrade tests run it with the token they made.
token_check() {
  local url
  for url in http://app:8080/api/v1/about/user http://next:80/api/user; do
    if ! printf 'header = "Authorization: Bearer %s"\n' "$1" \
        | docker run --rm -i --network "$DOCKER_NETWORK" "$CURL_IMAGE" \
            -fsS --max-time 30 --config - -H 'Accept: application/vnd.api+json' \
            -o /dev/null "$url"; then
      echo "the token does not work at $url"
      return 1
    fi
  done
  echo "Firefly III accepts the token, and Firefly Pocket too"
}

smoke_test() {
  local url svc down="" _
  for url in http://app:8080/health http://importer:8080/health \
             http://next:80/ http://next:80/api/test; do
    for _ in $(seq 30); do
      internal_http "$url" 10 >/dev/null 2>&1 && continue 2
      sleep 10
    done
    echo "no answer from $url after five minutes"
    return 1
  done
  for svc in $(docker compose --project-directory "$COMPOSE_DIR" config --services); do
    [ -n "$(docker compose --project-directory "$COMPOSE_DIR" ps -q --status running "$svc")" ] || down="$down $svc"
  done
  if [ -n "$down" ]; then
    echo "not running:$down"
    return 1
  fi
  # The console has a network of its own: asked there.
  for _ in $(seq 6); do
    docker run --rm --network "$CONSOLE_NETWORK" "$CURL_IMAGE" -fsS --max-time 10 -o /dev/null \
      http://console:8080/health >/dev/null 2>&1 && break
    [ "$_" -lt 6 ] || { echo "no answer from the console (http://console:8080/health)"; return 1; }
    sleep 5
  done
  echo "Firefly III, the importer, Firefly Pocket and the console answer; every service runs"
}

# Same, but POST. internal_http_post <url> [max-seconds]
#
# The importer declares its trigger as `Route::post('/autoimport', ...)`, so a
# GET returns a bare 405 with no explanation — which is what this stack did
# every night until it was caught. Parameters still ride in the query string:
# the controller reads them with $request->input(), which sees query and body
# alike, and the query form is what upstream documents.
#
# --post30x keeps the method across a redirect; plain --location would silently
# downgrade the POST to a GET and land back on the same 405.
internal_http_post() {
  local url="$1" timeout="${2:-900}"
  docker run --rm --network "$DOCKER_NETWORK" "$CURL_IMAGE" \
    --fail --silent --show-error --location --post301 --post302 --post303 \
    --request POST --max-time "$timeout" "$url"
}

# check_importer_errors <rfc3339-timestamp>
#
# Did the import that started at <timestamp> actually work?
#
# /autoimport answers 200 even when the import failed — an expired PSD2 consent
# or a revoked token is reported only in the importer's own log. curl --fail
# cannot see that, so without this check the nightly run reports success while
# importing nothing, which is precisely this system's most likely failure mode.
#
# The verdict is the "Exit code is <NAME>." line, NOT a grep for ERROR-level
# messages. Every terminal outcome logs one (app/Console/AutoImports.php), and
# upstream logs even the successful one at ERROR level — so a naive ERROR grep
# flags every healthy run. The exit code is the only honest signal in there.
#
# Two outcomes are treated as fine:
#   SUCCESS               — worked.
#   NOTHING_WAS_IMPORTED  — returned whenever a run ends with zero messages AND
#                           zero warnings, i.e. an ordinary quiet night with no
#                           new bank activity. Alerting on it would fire most
#                           weekends and train you to ignore the alert. The
#                           failure it might mask is covered from the other
#                           side: a dead consent reports AGREEMENT_EXPIRED, a
#                           bad token NO_CONNECTION, and both alert.
#
# A third, narrower case: TOO_MANY_ERRORS_PROCESSING for a connection whose
# conversion logged "Zero transactions!". Upstream counts an empty fetch as one
# conversion error, so a bank with no new activity ends with this code instead of
# NOTHING_WAS_IMPORTED (seen nightly on 2026-11-03: two quiet Revolut accounts,
# while fireflyx:connections:report said import.success with 0 messages). It is
# accepted only while every such verdict is matched by its own "Zero transactions!"
# line; a real conversion failure has no such line and still fails.
#
# No exit code at all means the import never reached application code — a 405
# from calling the POST route with GET looks exactly like this — so that fails.
#
# Duplicates are expected, every night, by design: the lookback window overlaps
# on purpose. IGNORE_DUPLICATE_ERRORS=true makes the importer drop them from the
# error array it judges the exit code on (ApiSubmitter.php:393) — verified: a
# run of nothing but duplicates reports "0 error(s)" and NOTHING_WAS_IMPORTED.
# What that flag does NOT do is stop the raw Log::error() calls that happen
# before the filtering, so the duplicate lines are still in the log and have to
# be excluded here by hand. Upstream tags them [a117].
check_importer_errors() {
  local since="$1" log verdicts bad other quiet_conversion=0
  # `date -Is` output is RFC3339, which is what --since expects.
  log="$(docker compose --project-directory "$COMPOSE_DIR" \
           logs --no-log-prefix --since "$since" importer 2>/dev/null)"

  # Matched at any log level: the error paths in AutoImports.php report some of
  # these codes at DEBUG, and those are still failures.
  verdicts="$(printf '%s\n' "$log" | grep -oE 'Exit code is [A-Z_]+' | awk '{print $NF}')"

  if [ -z "$verdicts" ]; then
    echo "importer never logged an exit code — the import did not reach application code"
    printf '%s\n' "$log" | tail -n 20
    return 1
  fi

  bad="$(printf '%s\n' "$verdicts" | grep -vE '^(SUCCESS|NOTHING_WAS_IMPORTED)$' || true)"
  # Quiet nights: forgive as many TOO_MANY_ERRORS_PROCESSING verdicts as there
  # are "Zero transactions!" lines, and nothing beyond that.
  local zero_lines too_many
  zero_lines="$(printf '%s\n' "$log" | grep -c 'Zero transactions!' || true)"
  too_many="$(printf '%s\n' "$bad" | grep -c '^TOO_MANY_ERRORS_PROCESSING$' || true)"
  if [ "$too_many" -gt 0 ] && [ "$too_many" -le "$zero_lines" ]; then
    bad="$(printf '%s\n' "$bad" | grep -v '^TOO_MANY_ERRORS_PROCESSING$' || true)"
    quiet_conversion=1
  fi
  if [ -n "$bad" ]; then
    echo "importer finished with: ${bad//$'\n'/ }"
    printf '%s\n' "$log" | grep -E '\.(ERROR|CRITICAL|ALERT|EMERGENCY):' | tail -n 15
    return 1
  fi

  # Anything else at ERROR or worse, minus the lines known to be benign: the
  # mislevelled exit-code lines, and the duplicate rejections the overlapping
  # window produces on purpose.
  other="$(printf '%s\n' "$log" \
           | grep -E '\.(ERROR|CRITICAL|ALERT|EMERGENCY):' \
           | grep -vE 'Exit code is (SUCCESS|NOTHING_WAS_IMPORTED)' \
           | grep -v 'Duplicate of transaction' || true)"
  if [ "$quiet_conversion" -eq 1 ]; then
    other="$(printf '%s\n' "$other" \
             | grep -vE 'Zero transactions!|Too many errors in the data conversion' || true)"
  fi
  if [ -n "$other" ]; then
    echo "importer logged unexpected errors during this run:"
    printf '%s\n' "$other" | tail -n 15
    return 1
  fi

  echo "importer outcome: ${verdicts//$'\n'/ }"
  return 0
}

# Wrap a step so any failure alerts instead of dying quietly in a cron log.
# run_step <human name> <command...>
#
# Saves and restores the caller's errexit setting rather than unconditionally
# re-enabling it. A bare `set -e` here would switch errexit ON for callers
# that deliberately run without it, so the first failed step would abort the
# whole run — exactly the opposite of what nightly.sh wants.
run_step() {
  local name="$1"; shift
  local output status errexit_was_on=0
  case $- in *e*) errexit_was_on=1 ;; esac
  echo "==> ${name}"
  set +e
  output="$("$@" 2>&1)"
  status=$?
  [ "$errexit_was_on" -eq 1 ] && set -e
  if [ $status -ne 0 ]; then
    notify "Firefly Pocket: ${name} FAILED" "exit ${status}
$(printf '%s' "$output" | tail -c 800)"
    return $status
  fi
  printf '%s\n' "$output" | tail -n 5
  return 0
}

# Like run_step, but a failure does not alert: the caller turns it into a message
# that says what it means. All of the output goes to the log, because that is
# where the exact error is looked up.
# log_step <human name> <command...>
log_step() {
  local name="$1"; shift
  local output status errexit_was_on=0
  case $- in *e*) errexit_was_on=1 ;; esac
  echo "==> ${name}"
  set +e
  output="$("$@" 2>&1)"
  status=$?
  [ "$errexit_was_on" -eq 1 ] && set -e
  printf '%s\n' "$output"
  [ $status -eq 0 ] || echo "!! ${name} failed (exit ${status})"
  return $status
}
