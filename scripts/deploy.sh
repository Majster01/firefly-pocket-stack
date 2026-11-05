#!/usr/bin/env bash
#
# Make the server run what origin/master says. This is the server's half of the
# deploy pipeline (README "Deploying"): fireflyx-deploy.timer runs it every two
# minutes, under the lock the cron jobs take too, so it never runs beside the
# backup, the nightly import, a restore test or another deploy.
#
#     scripts/deploy.sh            # deploy origin/master if it moved since the last deploy
#     scripts/deploy.sh --force    # deploy now: after a failure, or to apply an edited .env
#
# Merging into master IS deploying. Tracked files are reset to master, so an
# edit made by hand on the server stops the deploy and alerts instead of being
# lost. compose/.env, compose/secrets/ and config/importers/ are not tracked and
# are never touched.
#
# The steps, stopping and alerting at the first failure:
#   1. pull every image. If one is missing, nothing has restarted yet. Nothing
#      is built here: every image comes from a registry, the suggester's too
#   2. if the image of Firefly III, Postgres or the importer is about to change:
#      back up, and prove the backup restores. They migrate databases on start
#   3. docker compose up -d --no-build --remove-orphans: compose restarts only
#      what changed (and Caddy, when the Caddyfile changed)
#   4. install the crontab
#   5. check that Firefly III, the importer and Firefly Pocket answer and every
#      service runs
#
# A failure goes to ntfy and the Firefly Pocket app. A success that upgraded a package
# ("Upgrade successful: Firefly III 6.6.6 → 6.7.0") goes to the Firefly Pocket app, for the
# devices that want it. Both also onto the commit in GitHub when
# DEPLOY_STATUS_TOKEN is set. A revision that failed is not tried again until
# master moves or --force.

set -uo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
cd "$REPO_ROOT" || exit 1

BRANCH=master
LOCK_FILE=/run/lock/fireflyx.lock
DEPLOYED_FILE="$REPO_ROOT/.deployed-rev"
FAILED_FILE="$REPO_ROOT/.deploy-failed"
# These migrate a database when a new image starts.
MIGRATING="app db importer"

compose() { docker compose --project-directory "$COMPOSE_DIR" "$@"; }

# github_status <rev> <state> <description>
#
# Optional: the result as a commit status ("deploy/server") on GitHub, so the
# commit list shows which revision the server runs. DEPLOY_STATUS_TOKEN in .env
# is a fine-grained token for this repository only, "Commit statuses: write".
# The token goes to curl on stdin, so it does not show in `ps`.
github_status() {
  [ -n "${DEPLOY_STATUS_TOKEN:-}" ] || return 0
  local slug
  slug="$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
  printf 'header = "Authorization: Bearer %s"\n' "$DEPLOY_STATUS_TOKEN" \
    | curl -fsS --max-time 15 -o /dev/null --config - \
        -H 'Accept: application/vnd.github+json' \
        --data "{\"state\":\"$2\",\"context\":\"deploy/server\",\"description\":$(json_string "$3" 140)}" \
        "https://api.github.com/repos/$slug/statuses/$1" \
    || echo "WARN: could not set the GitHub commit status" >&2
}

# ---------------------------------------------------------------- check ---
# Lock, see whether master moved, move the checkout to it, and continue in the
# new revision's copy of this script, so a change to it applies at once.
if [ "${1:-}" != --apply ]; then
  force=""
  [ "${1:-}" = --force ] && force=1

  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    [ -n "$force" ] || exit 0   # busy: the next tick tries again
    echo "==> waiting for the lock (a cron job or another deploy)" >&2
    flock -w 3600 9 || { echo "FATAL: still locked after an hour" >&2; exit 1; }
  fi

  git fetch -q origin "$BRANCH" || exit 1
  target="$(git rev-parse FETCH_HEAD)"
  deployed="$(cat "$DEPLOYED_FILE" 2>/dev/null || true)"
  if [ -z "$force" ]; then
    [ "$target" = "$deployed" ] && exit 0
    [ "$target" = "$(cat "$FAILED_FILE" 2>/dev/null || true)" ] && exit 0
  fi

  dirty="$(git status --porcelain --untracked-files=no)"
  if [ -n "$dirty" ]; then
    echo "$target" > "$FAILED_FILE"
    github_status "$target" failure "files were edited on the server"
    notify "Firefly Pocket: deploy of ${target:0:7} FAILED" "Tracked files were edited on the server. Put the change into master, or undo it (git checkout -- <file>), then scripts/deploy.sh --force:
$dirty"
    exit 1
  fi

  git reset -q --hard "$target"
  exec "$REPO_ROOT/scripts/deploy.sh" --apply "$deployed"
fi

# ---------------------------------------------------------------- apply ---
old="${2:-}"
new="$(git rev-parse HEAD)"
short="${new:0:7}"

stop() {
  echo "$new" > "$FAILED_FILE"
  github_status "$new" failure "$1 failed"
  exit 1
}

# step <name> <command...>: run_step alerts with the command's output on failure.
step() {
  local name="$1"; shift
  run_step "deploy $short: $name" "$@" || stop "$name"
}

# A registry hiccup should not need a --force. --ignore-buildable only matters
# until the suggester's first pin: until then its image is the one the server
# built, which no registry has.
pull_images() {
  local attempt
  for attempt in 1 2 3; do
    compose pull --quiet --ignore-buildable && return 0
    [ "$attempt" -lt 3 ] && sleep 30
  done
  return 1
}

# Is a database-migrating service about to start on a different image? Compared
# with what runs now, not with the last commit, so a deploy that failed half-way
# still gets its backup the next time.
needs_backup() {
  local config svc want have
  config="$(compose config --format json)" || return 0
  for svc in $MIGRATING; do
    # Not `config --images <svc>`: that lists the service's dependencies too.
    want="$(docker image inspect --format '{{.Id}}' "$(jq -r --arg s "$svc" '.services[$s].image' <<<"$config")" 2>/dev/null)"
    have="$(docker inspect --format '{{.Image}}' "$(compose ps -aq "$svc")" 2>/dev/null)"
    if [ -z "$want" ] || [ "$want" != "$have" ]; then
      echo "    $svc gets a new image"
      return 0
    fi
  done
  return 1
}

# The Caddyfile is a single-file bind mount and git replaces files by rename, so
# a running Caddy keeps serving the old one until it is recreated.
caddyfile_changed() {
  [ -z "$old" ] || ! git diff --quiet "$old" "$new" -- compose/Caddyfile 2>/dev/null
}

# The apps answer on the internal network (Firefly III may still be migrating,
# so each gets five minutes), and every service compose starts runs. Firefly
# Pocket's /api/test is a plain Laravel route: nginx, php-fpm and the app, no
# Firefly call and no login.
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
  for svc in $(compose config --services); do
    [ -n "$(compose ps -q --status running "$svc")" ] || down="$down $svc"
  done
  if [ -n "$down" ]; then
    echo "not running:$down"
    return 1
  fi
  echo "Firefly III, the importer and Firefly Pocket answer; every service runs"
}

echo "==> deploy $(git log --oneline -1) (last deployed: ${old:0:7})"
github_status "$new" pending "deploying"

step "pull images" pull_images
if needs_backup; then
  step "backup" "$REPO_ROOT/scripts/backup.sh"
  step "restore test" "$REPO_ROOT/scripts/restore-test.sh"
fi
# --no-build: an image that is missing stops the deploy instead of being built here.
step "start what changed" compose up -d --no-build --remove-orphans
if caddyfile_changed; then
  step "recreate Caddy for the new Caddyfile" compose up -d --force-recreate caddy
fi
step "install the crontab" crontab "$REPO_ROOT/crontab"
step "smoke test" smoke_test

echo "$new" > "$DEPLOYED_FILE"
rm -f "$FAILED_FILE"
github_status "$new" success "deployed"
changes=""
[ -n "$old" ] && [ "$old" != "$new" ] && changes="$(git log --format='- %s' "$old..$new" 2>/dev/null | head -n 8)"
echo "deployed $short: ${changes:-$(git log -1 --format='%s')}"

# Only a new package is worth a message: which one, and from what to what. A
# deploy that changed compose settings, scripts or the crontab says nothing; a
# failed one has already alerted.
upgrades="$(upgraded_packages "$old" "$new")"
if [ -n "$upgrades" ]; then
  notify_event upgrade.success "Upgrade successful" "$(awk 'NR > 1 { printf ", " } { printf "%s", $0 }' <<<"$upgrades")" /
fi
