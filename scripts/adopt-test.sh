#!/usr/bin/env bash
#
# The server agent, end to end (Server agent steps 2, 3 and 5), for CI's adopt
# job: a server that is a git checkout of master switches itself to release
# bundles, then follows its channel. Like the server, with these stand-ins:
# the "server" is a temporary directory instead of /opt, its origin a bare
# clone of this repository, the registry a directory (LOCAL_BUNDLES,
# scripts/agent.sh) and crontab a script that writes nothing.
#
#     scripts/adopt-test.sh            # BASE: the revision the server runs first, default
#                                      # the merge base with origin/master
#
#   1. the server runs BASE, booted with BASE's own boot test, with no channel set
#   2. master moves to this commit; BASE's deploy.sh deploys it, through this
#      commit's --apply: the contract between the two
#   3. a tick with nothing to deploy would switch over (scripts/adopt.sh), but
#      the way is not clear: it alerts once, then is quiet until --force
#   4. --force, and moving /opt/fireflyx fails: everything is put back, the
#      stack runs on, and the way is clear for another try
#   5. a tick with nothing to deploy switches
#   6. after the switch: the links, the state in the shared directory, the
#      settings store writing there, CHANNEL latest, the databases' containers
#      left running, and no container reading a file of the old checkout
#   7. a bundle of this commit on latest: deployed through --release and --up
#   8. a tick with nothing new does nothing
#   9. a bundle that changes the Caddyfile: Caddy, the console and the importer
#      recreated, Postgres, Firefly III and Firefly Pocket not; Caddy serves the
#      new file
#  10. a bundle whose image does not exist: nothing restarts, current goes
#      back, and it is not tried again until the channel moves
#  11. latest naming an older bundle: held, never deployed, not even forced
#  12. stable with no release: it says so, once, and stays
#  13. stable naming a new major: held until updates approve, then deployed
#  14. stable naming a release in the afternoon: it waits for 06:00
#  15. a pinned release: a new channel goes at once; an older pin is held
#  16. every container started again, as after a reboot, old releases pruned
#
# Not covered: a switch whose stack does not come back after /opt/fireflyx
# moved (it alerts with the way back, by hand).
#
# Needs Docker, sudo without a password, bash 5, jq, and network access to the
# registries. Never for the server: it uses the server's container names.

# ok always succeeds, so `test && ok ... || fail ...` is an if/else here; and
# lib.sh, sourced in subshells to check the stack, sets their REPO_ROOT only.
# shellcheck disable=SC2015,SC2031

set -euo pipefail
shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
ROOT="$work/opt/fireflyx"
export FIREFLYX_ROOT="$ROOT"
export FIREFLYX_RELEASES="$work/opt/fireflyx-releases"
export FIREFLYX_SHARED="$work/opt/fireflyx-shared"
export LOCAL_BUNDLES="$work/registry"
export FIREFLYX_LOCK="$work/lock"
base="${BASE:-$(git -C "$REPO_ROOT" merge-base HEAD origin/master)}"
head="$(git -C "$REPO_ROOT" rev-parse HEAD)"

failures=0
ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
die()  { echo "FATAL: $*" >&2; exit 1; }

compose() { docker compose --project-directory "$ROOT/compose" "$@"; }
finish() {
  local status=$?
  if [ "$status" -ne 0 ] || [ "$failures" -gt 0 ]; then
    echo "==> services:"
    compose ps -a 2>/dev/null || docker ps -a
  fi
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  sudo rm -rf "$work"
  exit "$status"
}
trap finish EXIT

# tick [args]: the timer's run, with crontab stood in for.
tick() { PATH="$work/fake:$PATH" "$ROOT/scripts/deploy.sh" "$@"; }
id_of() { docker inspect --format '{{.Id}}' "fireflyx-$1" 2>/dev/null || echo none; }
ids() { local s; for s in db app next; do printf '%s=%s ' "$s" "$(id_of "$s")"; done; }
current() { readlink "$FIREFLYX_RELEASES/current"; }
state() { cat "$FIREFLYX_SHARED/$1" 2>/dev/null || true; }

# bundle <dir> <tag...>: publish a bundle directory to the stand-in registry
# under a digest of its own, and point the tags at it.
bundle() {
  local dir="$1" digest tag; shift
  digest="sha256:$(cd "$dir" && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)"
  rm -rf "${LOCAL_BUNDLES:?}/$digest"
  cp -a "$dir" "$LOCAL_BUNDLES/$digest"
  for tag in "$@"; do echo "$digest" > "$LOCAL_BUNDLES/tags/$tag"; done
  echo "$digest"
}

# derive <from dir> <to dir> <build> <version>: a later bundle, as a later merge makes one.
derive() {
  cp -a "$1" "$2"
  jq --argjson b "$3" --arg v "$4" '.build = $b | .version = $v' "$1/release.json" > "$2/release.json"
}

mkdir -p "$work/fake" "$work/opt" "$LOCAL_BUNDLES/tags"
printf '#!/bin/sh\nexit 0\n' > "$work/fake/crontab"
chmod +x "$work/fake/crontab"

echo "==> 1. the server runs ${base:0:7}"
# Pushed, not cloned: CI checks out a merge commit no branch names.
git init -q --bare "$work/origin.git"
git -C "$REPO_ROOT" push -q "$work/origin.git" "$base:refs/heads/master" "$head:refs/heads/pr"
git clone -q "$work/origin.git" "$ROOT"
# Its origin as a server's is, while the boot test turns the deploy agent on:
# install-deploy-agent.sh takes only a GitHub URL, and only fetches from it.
git -C "$ROOT" remote set-url origin https://github.com/Majster01/firefly-pocket-stack.git
if ! KEEP=1 "$ROOT/scripts/boot-test.sh" > "$work/boot.log" 2>&1; then
  # Its steps and what failed; its dump of every service's log is in boot.log.
  grep -nE '^==> |FAIL|FATAL|^[A-Za-z].* (failed|refused)' "$work/boot.log" | grep -v '"level"' | tail -n 60
  die "the boot test of ${base:0:7} failed"
fi
echo "$base" > "$ROOT/.deployed-rev"
# From here on it follows the stand-in, whose master the test moves.
git -C "$ROOT" remote set-url origin "$work/origin.git"
# As a server from before channels: none set. A base that has them sets one in
# its boot test.
if jq -e 'has("CHANNEL")' "$ROOT/scripts/settings.json" >/dev/null; then
  "$ROOT/scripts/firefly-pocket" config unset CHANNEL >/dev/null
fi
ok "booted ${base:0:7}"

echo "==> 2. master moves to ${head:0:7}; ${base:0:7}'s deploy.sh deploys it"
git -C "$work/origin.git" update-ref refs/heads/master "$head"
tick > "$work/tick.log" 2>&1 || { cat "$work/tick.log"; die "the git deploy failed"; }
[ "$(cat "$ROOT/.deployed-rev")" = "$head" ] && ok "deployed ${head:0:7} from git" || fail "deployed $(cat "$ROOT/.deployed-rev")"
[ -d "$ROOT/.git" ] && [ ! -L "$ROOT" ] && ok "not switched yet: that waits for a tick with nothing to deploy" || fail "it switched at once"

echo "==> 3. the way is not clear: alerted once, then quiet until --force"
mkdir -p "$ROOT-git" && touch "$ROOT-git/in-the-way"
tick > "$work/tick.log" 2>&1 || true
[ -s "$ROOT/.adopt-failed" ] && grep -q "is there already" "$ROOT/.adopt-failed" && ok "it says why: $(cat "$ROOT/.adopt-failed")" || fail "no .adopt-failed: $(cat "$work/tick.log")"
[ -d "$ROOT/.git" ] && [ ! -e "$FIREFLYX_SHARED/compose/.env" ] && ok "nothing moved" || fail "something moved"
rm -rf "$ROOT-git"
tick > "$work/tick.log" 2>&1
[ -d "$ROOT/.git" ] && ! grep -q 'adopt:' "$work/tick.log" && ok "the next tick is quiet, the way clear or not" || fail "it tried again: $(cat "$work/tick.log")"

echo "==> 4. --force, and the switch itself fails: everything put back"
mkdir -p "$work/fake-sudo"
cat > "$work/fake-sudo/sudo" <<'FAKE'
#!/bin/sh
# The real sudo, but moving /opt/fireflyx fails.
[ "$2" = mv ] && [ "$3" = -T ] && { echo "stand-in sudo: no" >&2; exit 1; }
exec /usr/bin/sudo "$@"
FAKE
chmod +x "$work/fake-sudo/sudo"
before="$(ids)"
if PATH="$work/fake-sudo:$work/fake:$PATH" "$ROOT/scripts/adopt.sh" --force > "$work/adopt.log" 2>&1; then
  fail "the switch passed though moving $ROOT failed"
fi
[ -d "$ROOT/.git" ] && [ ! -L "$ROOT" ] && [ -f "$ROOT/compose/.env" ] && [ -f "$ROOT/compose/config.json" ] && [ -f "$ROOT/.deployed-rev" ] \
  && ok "the state is back in the checkout" || fail "not put back: $(ls -la "$ROOT/compose")"
[ -z "$(find "$FIREFLYX_SHARED" "$FIREFLYX_RELEASES" -mindepth 1 2>/dev/null)" ] \
  && ok "the shared and releases directories are empty again" || fail "left behind: $(ls -RA "$FIREFLYX_SHARED" "$FIREFLYX_RELEASES")"
grep -q "could not move" "$ROOT/.adopt-failed" && ok "it says why" || fail ".adopt-failed: $(cat "$ROOT/.adopt-failed")"
( source "$ROOT/scripts/lib.sh" && smoke_test >/dev/null ) && [ "$(ids)" = "$before" ] \
  && ok "the stack runs on, as it was" || fail "the stack after an undone switch: $before -> $(ids)"

echo "==> 5. once the way is clear, a tick with nothing to deploy switches"
rm -f "$ROOT/.adopt-failed"   # what --force does, from the deploy
tick > "$work/tick.log" 2>&1 || { cat "$work/tick.log"; fail "the tick that switches failed"; }
grep -q 'adopt: done' "$work/tick.log" && [ -L "$ROOT" ] && [ -d "$ROOT-git/.git" ] && [ ! -e "$FIREFLYX_SHARED/.adopt-failed" ] \
  && ok "switched, and the checkout kept as $ROOT-git" || fail "not switched: $(tail -n 20 "$work/tick.log")"

echo "==> 6. after the switch"
[ "$(readlink "$ROOT")" = "$FIREFLYX_RELEASES/current" ] && [ "$(current)" = "git-${head:0:7}" ] \
  && ok "$ROOT -> releases/current -> $(current)" || fail "$ROOT -> $(readlink "$ROOT"), current -> $(current)"
linked=1
for p in compose/.env compose/config.json compose/secrets compose/console; do
  [ -L "$ROOT/$p" ] && [ -e "$FIREFLYX_SHARED/$p" ] || { linked=""; fail "$p is not a link into the shared state"; }
done
[ -z "$linked" ] || ok "the state is in $FIREFLYX_SHARED, linked from the release"
[ "$(jq -r '.build' "$ROOT/release.json")" = "$(git -C "$ROOT-git" rev-list --count --first-parent HEAD)" ] \
  && ok "the first release knows its build, so no channel takes it backwards" || fail "release.json: $(cat "$ROOT/release.json")"
[ ! -e "$ROOT-git/compose/config.json" ] && [ ! -e "$ROOT-git/compose/.env" ] \
  && ok "and not in the old checkout" || fail "the old checkout still has state"
[ "$(jq -r .CHANNEL "$FIREFLYX_SHARED/compose/config.json")" = latest ] && ok "CHANNEL latest, as none was set: it goes on following master" || fail "CHANNEL is $(jq -r .CHANNEL "$FIREFLYX_SHARED/compose/config.json")"
"$ROOT/scripts/firefly-pocket" config set TZ Europe/Ljubljana >/dev/null
[ -L "$ROOT/compose/config.json" ] && grep -qx 'TZ=Europe/Ljubljana' "$FIREFLYX_SHARED/compose/.env" \
  && ok "config set writes the shared store, and the links stay" || fail "config set: $(ls -la "$ROOT/compose")"
"$ROOT/scripts/firefly-pocket" config set TZ Etc/UTC >/dev/null
[ "$(ids)" = "$before" ] && ok "Postgres, Firefly III and Firefly Pocket ran on: $(ids)" || fail "recreated: $before -> $(ids)"
echo "# from the old checkout" >> "$ROOT-git/compose/Caddyfile"
touch "$ROOT-git/services/console/from-the-old-checkout" "$ROOT-git/config/from-the-old-checkout"
! docker exec fireflyx-caddy grep -q 'from the old checkout' /etc/caddy/Caddyfile \
  && ! docker exec fireflyx-console ls /app/from-the-old-checkout >/dev/null 2>&1 \
  && ! docker exec fireflyx-importer ls /fireflyx/config/from-the-old-checkout >/dev/null 2>&1 \
  && ok "no container reads a file of the old checkout" || fail "a container still reads $ROOT-git"
# shellcheck source=lib.sh
( source "$ROOT/scripts/lib.sh" && smoke_test >/dev/null && token_check "$IMPORTER_FIREFLY_TOKEN" >/dev/null ) \
  && ok "the stack answers, and the token made on ${base:0:7} works" || fail "the stack or the token after the switch"

echo "==> 7. a bundle of ${head:0:7} on latest"
"$REPO_ROOT/scripts/make-bundle.sh" "$work/b1" > "$work/bundle.log" 2>&1 || { cat "$work/bundle.log"; die "make-bundle.sh failed"; }
d1="$(bundle "$work/b1" latest)"
v1="$(jq -r .version "$work/b1/release.json")"
build1="$(jq -r .build "$work/b1/release.json")"
tick > "$work/tick.log" 2>&1 || { cat "$work/tick.log"; fail "the deploy of $v1 failed"; }
[ "$(state .deployed-digest)" = "$d1" ] && [ "$(current)" = "$v1-${d1:7:12}" ] \
  && ok "deployed $v1: current -> $(current)" || fail "deployed $(state .deployed-digest), current -> $(current): $(tail -n 20 "$work/tick.log")"
[ "$(state .deployed-version)" = "$v1" ] && [ "$(state .last-channel)" = latest ] && ok "it knows what it runs" || fail "state: $(state .deployed-version) $(state .last-channel)"
for p in compose/.env compose/secrets config/importers; do
  [ -L "$ROOT/$p" ] || fail "the release's $p is no link"
done
[ "$(readlink "$ROOT/.state")" = "$FIREFLYX_SHARED" ] && ok "the release links its state" || fail "the release's .state: $(readlink "$ROOT/.state")"
"$ROOT/scripts/firefly-pocket" updates > "$work/updates.out"
grep -q "runs      $v1" "$work/updates.out" && ok "updates status says it" || fail "updates status: $(cat "$work/updates.out")"

echo "==> 8. nothing new"
before="$(ids) caddy=$(id_of caddy)"
tick > "$work/tick.log" 2>&1
[ "$(ids) caddy=$(id_of caddy)" = "$before" ] && [ ! -s "$work/tick.log" ] && ok "a tick with nothing new does nothing" || fail "it did: $(cat "$work/tick.log")"

echo "==> 9. a bundle that changes the Caddyfile"
derive "$work/b1" "$work/b2" $((build1 + 1)) "${v1%.*}.$(( ${v1##*.} + 1 ))"
echo "# the second bundle" >> "$work/b2/compose/Caddyfile"
d2="$(bundle "$work/b2" latest)"
before="$(ids)"
caddy="$(id_of caddy)"
tick > "$work/tick.log" 2>&1 || { cat "$work/tick.log"; fail "the deploy of the second bundle failed"; }
[ "$(state .deployed-digest)" = "$d2" ] && ok "deployed the second bundle" || fail "deployed $(state .deployed-digest)"
[ "$(ids)" = "$before" ] && ok "Postgres, Firefly III and Firefly Pocket ran on" || fail "recreated: $before -> $(ids)"
[ "$(id_of caddy)" != "$caddy" ] && docker exec fireflyx-caddy grep -q 'the second bundle' /etc/caddy/Caddyfile \
  && ok "Caddy was recreated, and serves the new Caddyfile" || fail "Caddy runs the old Caddyfile"
( source "$ROOT/scripts/lib.sh" && smoke_test >/dev/null ) && ok "the stack answers" || fail "the smoke test after the second bundle"

echo "==> 10. a bundle whose image does not exist"
derive "$work/b2" "$work/b3" $((build1 + 2)) "${v1%.*}.$(( ${v1##*.} + 2 ))"
sed -i -E 's#^(    image: amir20/dozzle:[^@]+)@sha256:[0-9a-f]{64}#\1@sha256:0000000000000000000000000000000000000000000000000000000000000000#' "$work/b3/compose/docker-compose.yml"
d3="$(bundle "$work/b3" latest)"
before="$(ids) caddy=$(id_of caddy)"
if tick > "$work/tick.log" 2>&1; then fail "a bundle with a missing image deployed"; fi
[ "$(current)" = "$(jq -r .version "$work/b2/release.json")-${d2:7:12}" ] && ok "current went back to what runs" || fail "current -> $(current)"
[ "$(ids) caddy=$(id_of caddy)" = "$before" ] && ok "nothing restarted" || fail "restarted: $before -> $(ids) caddy=$(id_of caddy)"
[ "$(state .deploy-failed)" = "$d3" ] && ok "it is marked failed" || fail ".deploy-failed: $(state .deploy-failed)"
tick > "$work/tick.log" 2>&1
[ ! -s "$work/tick.log" ] && ok "and not tried again until the channel moves" || fail "tried again: $(cat "$work/tick.log")"

echo "==> 10b. latest names a bundle from before the server agent"
cp -a "$work/b2" "$work/b0"
jq 'del(.build) | .version = "0.9.0-old"' "$work/b2/release.json" > "$work/b0/release.json"
printf '#!/bin/sh\nexit 99\n' > "$work/b0/scripts/deploy.sh"   # its code must never run
d0="$(bundle "$work/b0" latest)"
before="$(ids) caddy=$(id_of caddy) $(current)"
tick > "$work/tick.log" 2>&1
[ "$(state .held)" = "$d0 before-agent" ] && [ "$(state .deployed-digest)" = "$d2" ] && [ "$(ids) caddy=$(id_of caddy) $(current)" = "$before" ] \
  && grep -q "from before the server agent" "$work/tick.log" && ok "held, never run: $(cat "$work/tick.log")" || fail "before-agent: $(state .held): $(cat "$work/tick.log")"
tick > "$work/tick.log" 2>&1
[ ! -s "$work/tick.log" ] && ok "said once" || fail "said again: $(cat "$work/tick.log")"
tick --force > "$work/tick.log" 2>&1
[ "$(state .deployed-digest)" = "$d2" ] && grep -q "from before the server agent" "$work/tick.log" && ok "not even with --force, which says why" || fail "--force: $(cat "$work/tick.log")"
"$ROOT/scripts/firefly-pocket" updates > "$work/updates.out"
grep -q "from before the server agent" "$work/updates.out" && ok "updates status says it" || fail "updates: $(cat "$work/updates.out")"

echo "==> 11. latest names an older bundle"
echo "$d1" > "$LOCAL_BUNDLES/tags/latest"
tick > "$work/tick.log" 2>&1
[ "$(state .deployed-digest)" = "$d2" ] && [ "$(state .held)" = "$d1 backwards" ] && grep -q "never moves backwards" "$work/tick.log" \
  && ok "held: it never moves backwards" || fail "held: $(state .held), runs $(state .deployed-digest): $(cat "$work/tick.log")"
tick --force > "$work/tick.log" 2>&1
[ "$(state .deployed-digest)" = "$d2" ] && ok "not even with --force" || fail "--force deployed an older bundle"

echo "==> 12. stable, before the first release"
"$ROOT/scripts/firefly-pocket" config set CHANNEL stable >/dev/null
tick > "$work/tick.log" 2>&1
grep -q "no stable release yet" "$work/tick.log" && [ "$(state .no-release)" = stable ] && ok "it says so: $(head -n 1 "$work/tick.log")" || fail "no stable: $(cat "$work/tick.log")"
tick > "$work/tick.log" 2>&1
[ ! -s "$work/tick.log" ] && [ "$(state .deployed-digest)" = "$d2" ] && ok "once, and it stays on what runs" || fail "said again: $(cat "$work/tick.log")"

echo "==> 13. stable names a new major"
derive "$work/b2" "$work/b4" $((build1 + 3)) "2.0.0-dev.1"
d4="$(bundle "$work/b4" stable 2.0.0)"
tick > "$work/tick.log" 2>&1
[ "$(state .held)" = "$d4 major 2" ] && [ "$(state .deployed-digest)" = "$d2" ] && ok "2.0.0 is held for a person" || fail "held: $(state .held): $(cat "$work/tick.log")"
tick > "$work/tick.log" 2>&1
[ ! -s "$work/tick.log" ] && ok "and announced once" || fail "announced again: $(cat "$work/tick.log")"
PATH="$work/fake:$PATH" "$ROOT/scripts/firefly-pocket" updates approve > "$work/tick.log" 2>&1 || { cat "$work/tick.log"; fail "updates approve failed"; }
[ "$(state .deployed-digest)" = "$d4" ] && [ "$(state .deployed-version)" = 2.0.0 ] && [ "$(state .approved-major)" = 2 ] \
  && ok "updates approve deployed 2.0.0" || fail "after approve: $(state .deployed-version): $(tail -n 20 "$work/tick.log")"
[ ! -e "$FIREFLYX_SHARED/.held" ] && ok "nothing is held any more" || fail "still held: $(state .held)"
( source "$ROOT/scripts/lib.sh" && smoke_test >/dev/null && token_check "$IMPORTER_FIREFLY_TOKEN" >/dev/null ) \
  && ok "the stack answers, and the token still works" || fail "the stack or the token at the end"
# Three kept, and the previous release (the one before 2.0.0, of step 9) is
# never pruned, however old: four.
n="$(find "$FIREFLYX_RELEASES" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l)"
[ "$n" -eq 4 ] && [ ! -e "$FIREFLYX_RELEASES/git-${head:0:7}" ] && [ ! -e "$FIREFLYX_RELEASES/$v1-${d1:7:12}" ] \
  && [ -d "$FIREFLYX_RELEASES/$(current)" ] && [ -d "$FIREFLYX_RELEASES/$(jq -r .version "$work/b2/release.json")-${d2:7:12}" ] \
  && ok "the oldest releases went; the current and the previous one stay" || fail "$n release directories kept: $(ls "$FIREFLYX_RELEASES")"


echo "==> 14. stable names a release in the afternoon: it waits for the morning"
derive "$work/b4" "$work/b5" $((build1 + 4)) "2.1.0-dev.1"
d5="$(bundle "$work/b5" stable 2.0.1)"
FIREFLYX_HOUR=13 tick > "$work/tick.log" 2>&1
[ "$(state .pending)" = "$d5 2.0.1" ] && [ "$(state .deployed-digest)" = "$d4" ] && grep -q "between 06:00 and 08:00" "$work/tick.log" \
  && ok "2.0.1 waits: $(cat "$work/tick.log")" || fail "pending: $(state .pending): $(cat "$work/tick.log")"
FIREFLYX_HOUR=14 tick > "$work/tick.log" 2>&1
[ ! -s "$work/tick.log" ] && ok "said once" || fail "said again: $(cat "$work/tick.log")"
FIREFLYX_HOUR=06 tick > "$work/tick.log" 2>&1 || { cat "$work/tick.log"; fail "the morning deploy failed"; }
[ "$(state .deployed-version)" = 2.0.1 ] && [ ! -e "$FIREFLYX_SHARED/.pending" ] && ok "deployed at 06:00" || fail "at 06:00: $(state .deployed-version): $(tail -n 20 "$work/tick.log")"

echo "==> 15. a pinned release: a new channel goes at once; an older pin is held"
derive "$work/b5" "$work/b6" $((build1 + 5)) "2.1.0-dev.2"
bundle "$work/b6" 2.0.2 >/dev/null
"$ROOT/scripts/firefly-pocket" config set CHANNEL 2.0.2 >/dev/null
FIREFLYX_HOUR=13 tick > "$work/tick.log" 2>&1 || { cat "$work/tick.log"; fail "the deploy of the pin failed"; }
[ "$(state .deployed-version)" = 2.0.2 ] && [ "$(state .last-channel)" = 2.0.2 ] && ok "pinned to 2.0.2, in the afternoon" || fail "pin: $(state .deployed-version): $(tail -n 20 "$work/tick.log")"
"$ROOT/scripts/firefly-pocket" config set CHANNEL 2.0.1 >/dev/null
FIREFLYX_HOUR=06 tick > "$work/tick.log" 2>&1
[ "$(state .deployed-version)" = 2.0.2 ] && [[ "$(state .held)" == *" backwards" ]] && ok "a pin to an older release is held" || fail "older pin: $(state .deployed-version) $(state .held)"

echo "==> 16. every container started again, as after a reboot, with old releases gone"
compose restart >/dev/null 2>&1 || fail "compose restart"
( source "$ROOT/scripts/lib.sh" && smoke_test >/dev/null && token_check "$IMPORTER_FIREFLY_TOKEN" >/dev/null ) \
  && ok "the stack comes back from the releases kept" || fail "the stack after a restart"
# db, app and next were made while step 7's release was current, which is
# pruned: started again, they mount the release that runs, and nothing makes
# the pruned one again.
[ ! -e "$FIREFLYX_RELEASES/$v1-${d1:7:12}" ] && ok "the release they were made in stays gone" || fail "a restart made $v1-${d1:7:12} again: $(ls -la "$FIREFLYX_RELEASES")"

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures"
  exit 1
fi
echo "the server switched to release bundles and followed its channel"
