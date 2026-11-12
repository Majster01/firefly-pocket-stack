#!/usr/bin/env bash
#
# Make the server run what its channel says. This is the server's half of the
# deploy pipeline (README "Deploying"): fireflyx-deploy.timer runs it every two
# minutes, under the lock the cron jobs take too, so it never runs beside the
# backup, the nightly import, a restore test or another deploy.
#
#     scripts/deploy.sh            # deploy what the channel names, if it moved
#     scripts/deploy.sh --force    # now: after a failure, outside the morning
#                                  # window, or to apply a changed setting
#
# The channel is the CHANNEL setting (scripts/channels.sh): latest, every merge
# into master within minutes; stable, the newest release, between 06:00 and
# 08:00, a new major only after `scripts/firefly-pocket updates approve`; or one
# release, X.Y.Z. A server never moves backwards. Empty is latest.
#
# Two kinds of server:
#   - a git checkout of master (every server before the Server agent): it
#     fetches master and deploys it, as it always did, and on a tick with
#     nothing to deploy switches itself over to release bundles once
#     (scripts/adopt.sh)
#   - a server of release bundles: /opt/fireflyx -> /opt/fireflyx-releases/
#     current -> <version>-<digest>, its state in /opt/fireflyx-shared
#     (scripts/paths.sh). Each tick, in three parts:
#       1. this release's code: resolve the channel's tag to a digest, fetch
#          the bundle into releases/, and refuse an older one. Kept small, as
#          a mistake here can only be fixed by the release after
#       2. --release, the new release's code: is it a major nobody approved,
#          or outside the window? If not, point current at it
#       3. --up, from /opt/fireflyx again: the steps below
#
# compose/.env, the settings store, compose/secrets/ and config/importers/ are
# state, never in a release or a commit. A server with the settings store
# (scripts/config.sh) gets its .env written from it.
#
# The steps, stopping and alerting at the first failure:
#   0. with the settings store: write compose/.env from it, as this revision's
#      scripts/settings.json says. A hand edit to .env stops the deploy here
#   1. pull every image. If one is missing, nothing has restarted yet (and a
#      release goes back to the one before). Nothing is built here: every
#      image comes from a registry, the suggester's too
#   2. if the image of Firefly III, Postgres or the importer is about to change:
#      back up, and prove the backup restores. They migrate databases on start
#   3. docker compose up -d --no-build --remove-orphans: compose restarts only
#      what changed, and then the services that mount the release's files
#      (RELEASE_MOUNTS, lib.sh) are recreated. The console's directories and
#      status are written first (scripts/console.sh)
#   4. install the crontab
#   5. check that Firefly III, the importer and Firefly Pocket answer and every
#      service runs
#   6. on a server set up before the console could sign in with Firefly III: its
#      client, registered once (scripts/console.sh client). A failure only warns
#
# A failure goes to ntfy and the Firefly Pocket app. A success that upgraded a package
# ("Upgrade successful: Firefly III 6.6.6 → 6.7.0") goes to the Firefly Pocket app, for the
# devices that want it. Both also onto the commit in GitHub when
# DEPLOY_STATUS_TOKEN is set. A revision or bundle that failed is not tried
# again until the channel moves or --force.

set -uo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
# shellcheck source=channels.sh
source "$REPO_ROOT/scripts/channels.sh"
cd "$REPO_ROOT" || exit 1

BRANCH=master
AGENT="$REPO_ROOT/scripts/agent.sh"
# What the deploy knows, under STATE_DIR (paths.sh).
DEPLOYED_REV="$STATE_DIR/.deployed-rev"           # git: the revision deployed
DEPLOYED="$STATE_DIR/.deployed-digest"            # releases: the bundle deployed
DEPLOYED_VERSION="$STATE_DIR/.deployed-version"   # and its version, as the channel names it
FAILED_FILE="$STATE_DIR/.deploy-failed"           # what failed: a revision or a digest
HELD="$STATE_DIR/.held"                           # "<digest> <why>": not deployed, on purpose
PENDING="$STATE_DIR/.pending"                     # "<digest> <version>": waits for the morning window
APPROVED="$STATE_DIR/.approved-major"             # the major updates approve let through
LAST_CHANNEL="$STATE_DIR/.last-channel"           # the channel of the last deploy
NO_RELEASE="$STATE_DIR/.no-release"               # the channel that names nothing yet
KEEP_RELEASES=3

compose() { docker compose --project-directory "$COMPOSE_DIR" "$@"; }

# github_status <rev> <state> <description>: the deploy's commit status,
# deploy/server. The canary gate of a release reads it (scripts/release.sh).
github_status() { commit_status deploy/server "$@"; }

# channel: what the server follows; not set is latest, as before CHANNEL was.
channel() {
  local ch
  ch="$(setting CHANNEL)"
  echo "${ch:-latest}"
}

# once <file> <line>: write the line, and say whether it is new, so a held or
# waiting release is logged and announced once, not every two minutes.
once() {
  [ "$(cat "$1" 2>/dev/null || true)" != "$2" ] || return 1
  printf '%s\n' "$2" > "$1"
}

# ------------------------------------------------------------- applying ---
# The steps both kinds of server run. STOP is what a failed step calls.

# step <name> <command...>: run_step alerts with the command's output on failure.
step() {
  local name="$1"; shift
  run_step "deploy $LABEL: $name" "$@" || "$STOP" "$name"
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

# prepare: steps 0 to 2. Nothing has restarted when one of them fails.
prepare() {
  if [ -f "$STATE_DIR/compose/config.json" ]; then
    step "write compose/.env from the settings" "$REPO_ROOT/scripts/firefly-pocket" config render
    # What was loaded at the start came from the .env before this one.
    # shellcheck source=lib.sh
    source "$REPO_ROOT/scripts/lib.sh"
  fi
  step "pull images" pull_images
  if needs_backup; then
    step "backup" "$REPO_ROOT/scripts/backup.sh"
    step "restore test" "$REPO_ROOT/scripts/restore-test.sh"
  fi
}

# start: steps 3 to 6.
start() {
  # The console's directories, made by this user before compose would make them as
  # root, and the status it shows (scripts/console.sh). Never stops a deploy.
  "$REPO_ROOT/scripts/console.sh" status || echo "WARN: could not write the console's status (exit $?)" >&2
  # --no-build: an image that is missing stops the deploy instead of being built here.
  step "start what changed" compose up -d --no-build --remove-orphans
  # A container keeps the files it was created with: a single-file mount the
  # one git replaced by rename, a directory mount the release it was made in.
  # shellcheck disable=SC2086  # a list of services
  step "recreate what mounts the release" compose up -d --no-build --no-deps --force-recreate $RELEASE_MOUNTS
  step "install the crontab" crontab "$REPO_ROOT/crontab"
  step "smoke test" smoke_test
  # The "Sign in with Firefly III" clients of the console and of Firefly Pocket:
  # made on a server set up before they existed, and moved to the hostname the
  # stack now answers on after a change of domain or of the defaults. A no-op
  # otherwise; never stops a deploy.
  if [ -n "${IMPORTER_FIREFLY_TOKEN:-}" ]; then
    "$REPO_ROOT/scripts/console.sh" client \
      || echo "WARN: could not register the sign-in clients (exit $?)" >&2
  fi
}

# announce_upgrades <old compose file>: only a new package is worth a message:
# which one, and from what to what. A deploy that changed compose settings,
# scripts or the crontab says nothing; a failed one has already alerted.
announce_upgrades() {
  local upgrades
  upgrades="$(upgraded_packages "$1" "$COMPOSE_DIR/docker-compose.yml")"
  if [ -n "$upgrades" ]; then
    notify_event upgrade.success "Upgrade successful" "$(awk 'NR > 1 { printf ", " } { printf "%s", $0 }' <<<"$upgrades")" /
  fi
}

# --------------------------------------------------------- git: apply ---
# The new revision's copy of this script, after the check below moved the
# checkout. Its arguments are the contract with every older deploy.sh, which
# execs it: --apply <the revision deployed before>.
apply_git() {
  local old="$1" new
  new="$(git rev-parse HEAD)"
  LABEL="${new:0:7}"
  NEW_REV="$new"
  STOP=stop_git
  echo "==> deploy $(git log --oneline -1) (last deployed: ${old:0:7})"
  github_status "$new" pending "deploying"
  prepare
  start
  echo "$new" > "$DEPLOYED_REV"
  rm -f "$FAILED_FILE"
  github_status "$new" success "deployed"
  local changes=""
  [ -n "$old" ] && [ "$old" != "$new" ] && changes="$(git log --format='- %s' "$old..$new" 2>/dev/null | head -n 8)"
  echo "deployed $LABEL: ${changes:-$(git log -1 --format='%s')}"
  if [ -n "$old" ]; then
    git show "$old:compose/docker-compose.yml" > "$STATE_DIR/.compose-before.yml" 2>/dev/null \
      && announce_upgrades "$STATE_DIR/.compose-before.yml"
    rm -f "$STATE_DIR/.compose-before.yml"
  fi
}

stop_git() {
  echo "$NEW_REV" > "$FAILED_FILE"
  github_status "$NEW_REV" failure "$1 failed"
  exit 1
}

# --------------------------------------------------------- git: check ---
# Lock held. See whether master moved, move the checkout to it, and continue in
# the new revision's copy of this script, so a change to it applies at once.
# With nothing to deploy, switch over to release bundles (scripts/adopt.sh).
check_git() {
  local force="$1" target deployed dirty
  # Only latest follows master. A server on another channel (a new one, which
  # the deploy agent's step set to stable) deploys the checkout it has, and
  # then switches to release bundles, which never go back from it.
  if [ "$(channel)" = latest ]; then
    git fetch -q origin "$BRANCH" || exit 1
    target="$(git rev-parse FETCH_HEAD)"
  else
    target="$(git rev-parse HEAD)"
  fi
  deployed="$(cat "$DEPLOYED_REV" 2>/dev/null || true)"
  if [ -z "$force" ]; then
    if [ "$target" = "$deployed" ]; then
      FIREFLYX_LOCKED=1 timeout 900 "$REPO_ROOT/scripts/adopt.sh" || echo "WARN: the switch to release bundles did not happen (exit $?)" >&2
      exit 0
    fi
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
}

# ----------------------------------------------------- releases: check ---
# Part 1, in the running release's code. Lock held.
check_release() {
  local force="$1" ch digest rc err deployed dir version running target releases old
  ch="$(channel)"
  releases="$(dirname "$(pwd -P)")"
  # The agent's own word on a missing tag goes, as it would every two minutes.
  err="$(mktemp)"
  digest="$("$AGENT" resolve "$ch" 2>"$err")"
  rc=$?
  [ "$rc" -eq 3 ] || cat "$err" >&2
  rm -f "$err"
  if [ "$rc" -eq 3 ]; then
    if once "$NO_RELEASE" "$ch"; then
      echo "==> no $ch release yet: this server stays on $(jq -r .version "$REPO_ROOT/release.json") until there is one"
    fi
    exit 0
  fi
  [ "$rc" -eq 0 ] || { echo "WARN: could not resolve $ch (exit $rc); the next tick tries again" >&2; exit 1; }
  rm -f "$NO_RELEASE"
  # What is held or waits is about the bundle the channel named then.
  [ "$(cut -d' ' -f1 "$HELD" 2>/dev/null)" = "$digest" ] || rm -f "$HELD"
  [ "$(cut -d' ' -f1 "$PENDING" 2>/dev/null)" = "$digest" ] || rm -f "$PENDING"

  deployed="$(cat "$DEPLOYED" 2>/dev/null || true)"
  # What runs: the release deployed last, which after a failure past the
  # switch is not the one current names.
  old="$(release_dir "$releases" "$deployed")"
  [ -n "$deployed" ] && [ -n "$old" ] || old="$(pwd -P)"
  if [ -z "$force" ]; then
    ! settled "$digest" "$deployed" "$(cut -d' ' -f1 "$HELD" 2>/dev/null)" "$(cat "$FAILED_FILE" 2>/dev/null)" || exit 0
  elif [ "$digest" = "$deployed" ]; then
    # --force on what runs: the steps again, as after a changed setting.
    dir="$(pwd -P)"
  fi

  if [ -z "${dir:-}" ]; then
    dir="$(release_dir "$releases" "$digest")"
    if [ -z "$dir" ]; then
      dir="$(fetch_release "$releases" "$digest")" || {
        echo "WARN: could not fetch the bundle $digest; the next tick tries again" >&2
        exit 1
      }
    fi
  fi

  # Never backwards: checked here, so that an older release's code never runs.
  running="$(jq -r '.build // empty' "$old/release.json" 2>/dev/null)"
  target="$(jq -r '.build // empty' "$dir/release.json")"
  version="$(jq -r .version "$dir/release.json")"
  # A bundle without a build was published before the server agent: its
  # deploy.sh cannot take over from here (no --release), so it is never run.
  if [ -z "$target" ]; then
    if once "$HELD" "$digest before-agent" || [ -n "$force" ]; then
      echo "==> $ch names $version, a bundle from before the server agent, which it cannot deploy; waiting for a newer one"
    fi
    exit 0
  fi
  if backwards "$running" "$target"; then
    # On latest, just switched from git before the bundle of that commit is
    # out: it comes within minutes, so wait without a word.
    if [ "$ch" = latest ] && [ -z "$deployed" ] && [[ "$(basename "$old")" == git-* ]] && [ -z "$force" ]; then
      exit 0
    fi
    if once "$HELD" "$digest backwards" || [ -n "$force" ]; then
      echo "==> $ch names $version (build $target), older than what runs (build $running): this server never moves backwards. It stays until $ch passes it; going back is a restore (README \"Restoring\")."
    fi
    exit 0
  fi
  exec "$dir/scripts/deploy.sh" --release "$REPO_ROOT" "$old" "$digest" "$force"
}

# release_dir <releases> <digest>: the release fetched for the digest before.
release_dir() {
  local d
  for d in "$1"/*-"${2:7:12}"; do
    [ -d "$d" ] && [ -f "$d/release.json" ] && { echo "$d"; return 0; }
  done
  return 0
}

# fetch_release <releases> <digest>: fetch and extract the bundle next to the
# others, as <version>-<12 digits of the digest>. Into a temporary directory
# first, so a fetch cut short leaves nothing that looks like a release.
fetch_release() {
  local releases="$1" digest="$2" tmp version dir
  tmp="$releases/.incoming-${digest:7:12}"
  rm -rf "$tmp"
  "$AGENT" fetch "$digest" "$tmp" >&2 || { rm -rf "$tmp"; return 1; }
  version="$(jq -r .version "$tmp/release.json")"
  [[ "$version" =~ ^[0-9A-Za-z.+-]+$ ]] || { rm -rf "$tmp"; echo "WARN: the bundle's version is $version" >&2; return 1; }
  # Linked before it gets its name: a release_dir is always whole.
  link_state "$tmp" || { rm -rf "$tmp"; return 1; }
  dir="$releases/$version-${digest:7:12}"
  rm -rf "$dir"
  mv "$tmp" "$dir"
  echo "$dir"
}

# --------------------------------------------------- releases: decide ---
# Part 2, in the new release's code, from its own directory: hold, wait or go.
decide_release() {
  local root="$1" old="$2" digest="$3" force="$4" ch version running approved changed verdict releases
  ch="$(channel)"
  case "$ch" in
    stable)
      # Known already while it waits for the window: no listing every tick.
      version="$(awk -v d="$digest" '$1 == d { print $2 }' "$PENDING" 2>/dev/null)"
      [ -n "$version" ] || version="$("$AGENT" release-of "$digest")" || exit 1
      if [ -z "$version" ]; then
        echo "==> stable names a bundle no release names yet (a release being made); looking again"
        exit 0
      fi ;;
    latest) version="$(jq -r .version "$REPO_ROOT/release.json")" ;;
    *) version="$ch" ;;
  esac
  running="$(cat "$DEPLOYED_VERSION" 2>/dev/null || jq -r .version "$old/release.json" 2>/dev/null || true)"
  approved="$(cat "$APPROVED" 2>/dev/null || true)"
  changed=""
  [ "$(cat "$LAST_CHANNEL" 2>/dev/null || true)" = "$ch" ] || changed=1
  verdict="$(verdict "$ch" "$version" "$running" "$approved" "${FIREFLYX_HOUR:-$(date +%H)}" "$changed" "$force")"
  case "$verdict" in
    hold-major*)
      if once "$HELD" "$digest major ${verdict#hold-major }"; then
        notify "Firefly Pocket $version needs you" "A new major release, $version, is waiting: it can need a value only you can give (its release notes say). This server stays on $running until you run, on it: scripts/firefly-pocket updates approve"
      fi
      exit 0 ;;
    wait-window)
      if once "$PENDING" "$digest $version"; then
        echo "==> $version is ready, and is deployed between $(printf '%02d' "$WINDOW_FROM"):00 and $(printf '%02d' "$WINDOW_TO"):00 (or now: scripts/firefly-pocket updates now)"
      fi
      exit 0 ;;
  esac
  releases="$(dirname "$REPO_ROOT")"
  switch_current "$releases" "$(basename "$REPO_ROOT")"
  exec "$root/scripts/deploy.sh" --up "$old" "$digest" "$version"
}

# switch_current <releases> <name>: point current at the release, in one rename.
switch_current() {
  ln -sfn "$2" "$1/.current.tmp" && mv -T "$1/.current.tmp" "$1/current"
}

# ------------------------------------------------------- releases: up ---
# Part 3, from /opt/fireflyx, which is the new release now.
up_release() {
  local old="$1" digest="$2" version="$3" commit releases
  releases="$(dirname "$(pwd -P)")"
  commit="$(jq -r .commit "$REPO_ROOT/release.json")"
  LABEL="$version"
  NEW_DIGEST="$digest" NEW_COMMIT="$commit" OLD_RELEASE="$old" RELEASES="$releases"
  STOP=stop_before_up
  echo "==> deploy $version (${commit:0:7}, ${digest:0:19}) over $(basename "$old")"
  github_status "$commit" pending "deploying $version"
  prepare
  STOP=stop_release
  start
  echo "$digest" > "$DEPLOYED"
  echo "$version" > "$DEPLOYED_VERSION"
  channel > "$LAST_CHANNEL"
  rm -f "$FAILED_FILE" "$HELD" "$PENDING"
  github_status "$commit" success "deployed $version"
  echo "deployed $version: $(jq -r '.components | map("\(.service) \(.tag)") | join(", ")' "$REPO_ROOT/release.json")"
  announce_upgrades "$old/compose/docker-compose.yml"
  prune "$releases" "$(basename "$(pwd -P)")" "$(basename "$old")"
}

# Nothing restarted yet: back to the release that runs, so current says what runs.
stop_before_up() {
  switch_current "$RELEASES" "$(basename "$OLD_RELEASE")"
  stop_release "$1"
}

stop_release() {
  echo "$NEW_DIGEST" > "$FAILED_FILE"
  github_status "$NEW_COMMIT" failure "$1 failed"
  exit 1
}

# prune <releases> <current> <previous>: keep the newest few release directories.
prune() {
  local name
  while IFS= read -r name; do
    echo "    removing the release $name"
    rm -rf "${1:?}/$name"
  done < <(find "$1" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%T@ %f\n' | sort -n | cut -d' ' -f2- \
             | prune_candidates "$KEEP_RELEASES" "$2" "$3")
}

# ------------------------------------------------------------------ main ---
case "${1:-}" in
  --apply) apply_git "${2:-}" ;;
  --release) decide_release "$2" "$3" "$4" "${5:-}" ;;
  --up) up_release "$2" "$3" "$4" ;;
  ""|--force)
    force=""
    [ "${1:-}" = --force ] && force=1
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
      [ -n "$force" ] || exit 0   # busy: the next tick tries again
      echo "==> waiting for the lock (a cron job or another deploy)" >&2
      flock -w 3600 9 || { echo "FATAL: still locked after an hour" >&2; exit 1; }
    fi
    if [ -d "$REPO_ROOT/.git" ]; then
      check_git "$force"
    else
      check_release "$force"
    fi
    ;;
  *) sed -n '8,10s/^#     //p' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
esac
