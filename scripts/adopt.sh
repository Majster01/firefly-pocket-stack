#!/usr/bin/env bash
#
# Switch a server from a git checkout to release bundles, once (Server agent
# step 2). scripts/deploy.sh runs it, under its lock, on a tick with nothing to
# deploy; so a server switches by itself within minutes of the merge that
# brings this, with nobody logged in. It deploys nothing new: it rearranges
# what runs, and the next tick deploys the channel's bundle the usual way.
#
#     scripts/adopt.sh            # deploy.sh runs it; it does nothing on a server that switched
#     scripts/adopt.sh --force    # again after it failed (.adopt-failed)
#
#   1. checks: a git checkout at the revision deployed, no failed deploy,
#      sudo without a password (the deploy agent's step needs it already),
#      and a way to keep CHANNEL
#   2. makes /opt/fireflyx-releases and /opt/fireflyx-shared, the admin user's
#   3. moves the state (scripts/paths.sh) into /opt/fireflyx-shared, by rename,
#      so the running containers keep the same files
#   4. copies the checkout's tracked files into releases/git-<commit>, with
#      a release.json that has no build, links its state, and points current
#      at it
#   5. CHANNEL: latest, unless the server set one. A server set up with the
#      deploy agent after this change has stable (install-deploy-agent.sh)
#   6. /opt/fireflyx becomes a link to /opt/fireflyx-releases/current; the
#      checkout stays, as /opt/fireflyx-git, for going back
#   7. recreates the services that mount the release's files (RELEASE_MOUNTS),
#      so none keeps a file in the old checkout, and checks the stack
#   8. says so: an alert, "switched to release bundles, following <channel>"
#
# A failure before 6 puts everything back and alerts once; a failure after it
# alerts with the way back. Either way .adopt-failed stops it from trying again
# until --force.
#
# FIREFLYX_ROOT, FIREFLYX_RELEASES and FIREFLYX_SHARED move the three paths, for
# the tests.

set -uo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

ROOT="${FIREFLYX_ROOT:-/opt/fireflyx}"
RELEASES="${FIREFLYX_RELEASES:-/opt/fireflyx-releases}"
SHARED="${FIREFLYX_SHARED:-/opt/fireflyx-shared}"
CHECKOUT="$REPO_ROOT"
FAILED="$CHECKOUT/.adopt-failed"
MOVED=()

say() { echo "==> adopt: $*"; }

# fail <why>: alert once, remember, and stop.
fail() {
  local why="$1${UNDONE:-}"
  if [ "$(cat "$FAILED" 2>/dev/null || true)" != "$why" ]; then
    notify "Firefly Pocket: the switch to release bundles FAILED" "$why"
  fi
  echo "$why" > "$FAILED"
  exit 1
}

# undo: everything back where it was, before /opt/fireflyx changed, and the
# two directories empty again, so that --force finds the way clear.
# A file that does not go back stays in $SHARED, never deleted: then UNDONE
# says where it is, and the alert says so.
undo() {
  local p kept=""
  for p in "${MOVED[@]}"; do
    # -T: never into a directory something made in its place meanwhile.
    if ! mv -T "$SHARED/$p" "$CHECKOUT/$p"; then
      echo "WARN: could not move $SHARED/$p back to $CHECKOUT/$p" >&2
      kept="$kept $p"
    fi
  done
  find "${RELEASES:?}" -mindepth 1 -delete 2>/dev/null || true
  if [ -z "$kept" ]; then
    find "${SHARED:?}" -mindepth 1 -delete 2>/dev/null || true
    UNDONE=""
  else
    UNDONE=" Not all of it went back:$kept are still in $SHARED; move them back by hand."
  fi
}

# ------------------------------------------------------------- checks ---
[ -d "$CHECKOUT/.git" ] || exit 0   # switched already
if [ -e "$FAILED" ] && [ "${1:-}" != --force ]; then
  exit 0
fi
[ "$(cd "$CHECKOUT" && pwd)" = "$ROOT" ] || { echo "adopt: this checkout is $CHECKOUT, not $ROOT; nothing to do" >&2; exit 0; }
# The deploy's lock: deploy.sh holds it already when it runs this.
if [ -z "${FIREFLYX_LOCKED:-}" ]; then
  exec 9>"$LOCK_FILE"
  flock -w 3600 9 || { echo "adopt: still locked after an hour" >&2; exit 1; }
fi
# Not yet, quietly: the deploy puts these right, and a later tick switches.
rev="$(git -C "$CHECKOUT" rev-parse HEAD)"
[ "$rev" = "$(cat "$CHECKOUT/.deployed-rev" 2>/dev/null || true)" ] || exit 0
[ ! -e "$CHECKOUT/.deploy-failed" ] || exit 0
[ -z "$(git -C "$CHECKOUT" status --porcelain --untracked-files=no)" ] || exit 0
sudo -n true 2>/dev/null || fail "Moving /opt/fireflyx needs sudo without a password, which this server's user does not have. Give it that (as terraform/cloud-init.yaml does), then: scripts/adopt.sh --force"
if [ -f "$CHECKOUT/compose/config.json" ]; then
  channel_kept="store"
elif [ -w "$CHECKOUT/compose/.env" ]; then
  channel_kept="env"
else
  fail "There is no compose/.env to keep CHANNEL in."
fi
for dir in "$RELEASES" "$SHARED" "${ROOT}-git"; do
  [ ! -e "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ] || fail "$dir is there already. Move it away, then: scripts/adopt.sh --force"
done
say "switching $ROOT (${rev:0:7}) to release bundles"

# --------------------------------------------------------- directories ---
user="$(id -un)"
sudo -n install -d -o "$user" -g "$(id -gn)" -m 755 "$RELEASES" "$SHARED" || fail "could not make $RELEASES and $SHARED"

# -------------------------------------------------------------- release ---
release="$RELEASES/git-${rev:0:7}"
read -ra paths <<<"$BUNDLE_PATHS"
mkdir -p "$release"
if ! git -C "$CHECKOUT" ls-files -z -- "${paths[@]}" | (cd "$CHECKOUT" && xargs -0 cp --parents -a -t "$release"); then
  undo
  fail "could not copy the checkout's files into $release"
fi
# Its build as make-bundle.sh counts it, so that a channel naming an older
# bundle than the checkout (stable, on a server cloned from master) is held,
# never deployed over databases the newer images migrated. Not from a shallow
# clone, which counts too few.
build=null
[ "$(git -C "$CHECKOUT" rev-parse --is-shallow-repository)" = true ] \
  || build="$(git -C "$CHECKOUT" rev-list --count --first-parent "$rev")"
jq -n --arg version "git-${rev:0:7}" --argjson build "$build" --arg commit "$rev" --arg source "$(repo_url)" \
  '{schema: 1, version: $version, commit: $commit, source: $source, components: []}
   + (if $build == null then {} else {build: $build} end)' > "$release/release.json"
# ---------------------------------------------------------------- state ---
# By rename, on one filesystem, so a container's mount keeps its file. Only
# what is there: a server without the settings store has no config.json.
for p in $STATE_PATHS .deployed-rev; do
  [ -e "$CHECKOUT/$p" ] || [ -L "$CHECKOUT/$p" ] || continue
  mkdir -p "$(dirname "$SHARED/$p")"
  if ! mv "$CHECKOUT/$p" "$SHARED/$p"; then
    undo
    fail "could not move $p to $SHARED"
  fi
  MOVED+=("$p")
done
# What every release links to is there, if only empty.
mkdir -p "$SHARED/compose/secrets" "$SHARED/compose/console" "$SHARED/config/importers"
rm -f "$CHECKOUT"/.shadow-rev "$CHECKOUT"/.shadow-wait "$CHECKOUT"/.shadow.log

STATE_DIR="$SHARED"
link_state "$release"
ln -sfn "$(basename "$release")" "$RELEASES/current"

# -------------------------------------------------------------- channel ---
# Kept as it is when the server set one; else latest, which is what it did.
if [ "$channel_kept" = store ]; then
  if ! jq -e 'has("CHANNEL")' "$SHARED/compose/config.json" >/dev/null; then
    "$release/scripts/firefly-pocket" config set --no-render CHANNEL latest >/dev/null \
      || { undo; fail "could not set CHANNEL in the settings store"; }
  fi
  channel="$(jq -r .CHANNEL "$SHARED/compose/config.json")"
else
  channel="$(STATE_DIR="$SHARED" setting CHANNEL)"
  if [ -z "$channel" ]; then
    { sed -i '/^CHANNEL=/d' "$SHARED/compose/.env" && echo 'CHANNEL=latest' >> "$SHARED/compose/.env"; } \
      || { undo; fail "could not set CHANNEL in compose/.env"; }
    channel=latest
  fi
fi

# ---------------------------------------------------------------- switch ---
# The one step that is not undone by itself: two renames as root, the lock held.
if ! sudo -n mv -T "$ROOT" "${ROOT}-git"; then
  undo
  fail "could not move $ROOT to ${ROOT}-git"
fi
if ! sudo -n ln -s "$RELEASES/current" "$ROOT"; then
  sudo -n mv -T "${ROOT}-git" "$ROOT"
  undo
  fail "could not make $ROOT a link to $RELEASES/current"
fi
echo "$rev" > "$SHARED/.adopted-from"
say "$ROOT -> $RELEASES/current -> $(basename "$release"); the checkout is ${ROOT}-git"

# ------------------------------------------------------------------ up ---
# From the new path, as the deploy runs it from now on: the same compose
# project, whose mounts now resolve into the release and the shared state.
back="To go back: sudo rm $ROOT && sudo mv ${ROOT}-git $ROOT, then move the files in $SHARED back into it."
FAILED="$SHARED/.adopt-failed"
cd "$ROOT" || fail "could not open $ROOT. $back"
# shellcheck disable=SC2086  # a list of services
if ! out="$(docker compose --project-directory "$ROOT/compose" up -d --no-build --no-deps --force-recreate $RELEASE_MOUNTS 2>&1 && smoke_test 2>&1)"; then
  printf '%s\n' "$out" >&2
  fail "Switched $ROOT to release bundles, but the stack did not come back: $(tail -n 3 <<<"$out") $back"
fi
printf '%s\n' "$out" | tail -n 3
# Its path unit watches the inbox by path, which is a link now.
sudo -n systemctl restart firefly-pocket-console.path 2>/dev/null || true
notify "Firefly Pocket: switched to release bundles" "This server now deploys the release bundle of its channel, $channel, instead of a git checkout (README \"Deploying\"). The old checkout is ${ROOT}-git; delete it once a release has deployed."
say "done"
