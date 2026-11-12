#!/usr/bin/env bash
#
# Tests of what the server agent decides (scripts/channels.sh), for CI's compose
# job. Needs bash, git and jq, no Docker and no registry:
#
#   1. CHANNEL: latest, stable or X.Y.Z, and nothing else
#   2. what a tick leaves alone: what runs, what is held, what failed
#   3. never backwards, and a build nobody knows is never backwards
#   4. the verdict: latest always goes; a new major on stable waits for an
#      approval of that major; stable and a pin wait for the morning window,
#      unless the channel changed or --force (which never skips a major)
#   5. release tags newest first, by number, and the next page of a tag list
#   6. which release directories may go
#   7. upgraded_packages between two compose files (lib.sh)
#   8. the bundle's version in a repository with releases, patch releases
#      included, and make-bundle.sh refusing a shallow clone

# ok always succeeds, so `test && ok ... || fail ...` is an if/else here.
# shellcheck disable=SC2015

set -euo pipefail
shopt -s inherit_errexit

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=channels.sh
source "$REPO_ROOT/scripts/channels.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
ok()   { echo "  ok    $*"; }
fail() { echo "  FAIL  $*"; failures=$((failures + 1)); }
# is <what> <want> <got>
is() { [ "$2" = "$3" ] && ok "$1" || fail "$1: want '$2', got '$3'"; }

echo "==> 1. CHANNEL"
for v in latest stable 1.2.3 0.0.1 10.20.30; do
  channel_valid "$v" && ok "$v is a channel" || fail "$v is refused"
done
for v in "" master 1.2 v1.2.3 1.2.3-dev.4 01.2.3 "1.2.3 " LATEST; do
  ! channel_valid "$v" && ok "'$v' is refused" || fail "'$v' is accepted"
done

echo "==> 2. what a tick leaves alone"
settled d1 d1 "" "" && ok "what runs" || fail "what runs is deployed again"
settled d2 d1 d2 "" && ok "what is held" || fail "a held release is deployed"
settled d3 d1 "" d3 && ok "what failed" || fail "a failed release is tried again"
! settled d4 d1 d2 d3 && ok "a new digest goes on" || fail "a new digest is left alone"
! settled d4 "" "" "" && ok "a server that deployed nothing yet goes on" || fail "nothing deployed: left alone"

echo "==> 3. never backwards"
backwards 120 119 && ok "an older build is backwards" || fail "119 after 120 is not backwards"
! backwards 120 120 && ok "the same build is not" || fail "the same build is backwards"
! backwards 120 121 && ok "a newer one is not" || fail "a newer build is backwards"
! backwards "" 50 && ok "after a switch from git (no build) nothing is" || fail "an unknown running build blocks"
! backwards 120 "" && ok "a bundle without a build is not" || fail "an unknown target build blocks"

echo "==> 4. the verdict"
# verdict <channel> <target> <running> <approved major> <hour> <changed> <force>
is "latest goes at night"                       apply           "$(verdict latest 2.0.0-dev.3 1.9.0-dev.40 "" 23 "" "")"
is "latest takes a major"                       apply           "$(verdict latest 2.0.0-dev.1 1.9.0-dev.40 "" 3 "" "")"
is "stable at 05:00 waits"                      wait-window     "$(verdict stable 1.4.3 1.4.2 "" 05 "" "")"
is "stable at 06:00 goes"                       apply           "$(verdict stable 1.4.3 1.4.2 "" 06 "" "")"
is "stable at 07:59 goes"                       apply           "$(verdict stable 1.4.3 1.4.2 "" 07 "" "")"
is "stable at 08:00 waits"                      wait-window     "$(verdict stable 1.4.3 1.4.2 "" 08 "" "")"
is "stable: --force skips the window"           apply           "$(verdict stable 1.4.3 1.4.2 "" 13 "" 1)"
is "stable: a changed channel skips it"         apply           "$(verdict stable 1.4.3 1.5.0-dev.7 "" 13 1 "")"
is "a pin waits for the window"                 wait-window     "$(verdict 1.4.3 1.4.3 1.4.2 "" 22 "" "")"
is "a pin goes in it"                           apply           "$(verdict 1.4.3 1.4.3 1.4.2 "" 6 "" "")"
is "a pin to a new major needs no approval"     apply           "$(verdict 2.0.0 2.0.0 1.4.2 "" 6 "" "")"
is "stable: a new major is held"                "hold-major 2"  "$(verdict stable 2.0.0 1.4.2 "" 6 "" "")"
is "stable: --force does not skip it"           "hold-major 2"  "$(verdict stable 2.0.0 1.4.2 "" 6 "" 1)"
is "stable: nor does a changed channel"         "hold-major 2"  "$(verdict stable 2.0.0 1.5.0-dev.3 "" 6 1 "")"
is "stable: an approved major goes"             apply           "$(verdict stable 2.0.0 1.4.2 2 6 "" "")"
is "stable: and 2.0.1 needs no approval again"  apply           "$(verdict stable 2.0.1 2.0.0 2 6 "" "")"
is "stable: 3.0.0 is held again"                "hold-major 3"  "$(verdict stable 3.0.0 2.4.1 2 6 "" "")"
is "stable: approved but outside the window"    wait-window     "$(verdict stable 2.0.0 1.4.2 2 4 "" "")"
is "stable after git (no major known)"          apply           "$(verdict stable 1.0.0 git-0e512de "" 6 "" "")"

echo "==> 5. release tags"
got="$(printf '%s\n' latest stable sha-0e512de 1.9.0 1.10.0 1.2.3 2.0.0 1.10.1 v3.0.0 1.0.0-dev.4 | releases_newest_first | paste -sd' ' -)"
is "newest first, by number, releases only" "2.0.0 1.10.1 1.10.0 1.9.0 1.2.3" "$got"
is "no release yet" "" "$(printf '%s\n' latest sha-0e512de | releases_newest_first)"
is "major of a release" 2 "$(major_of 2.0.1)"
is "major of a build" 1 "$(major_of 1.5.0-dev.37)"
is "major of a checkout" "" "$(major_of git-0e512de)"

printf 'HTTP/2 200\r\nlink: </v2/o/r/tags/list?last=sha-1&n=1000>; rel="next"\r\n\r\n' > "$work/h1"
is "the next page, a path on the registry" "https://ghcr.io/v2/o/r/tags/list?last=sha-1&n=1000" "$(next_page ghcr.io "$work/h1")"
printf 'Link: <https://other.io/v2/o/r/tags/list?last=x>; rel="next"\n' > "$work/h2"
is "the next page, a whole URL" "https://other.io/v2/o/r/tags/list?last=x" "$(next_page ghcr.io "$work/h2")"
printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n' > "$work/h3"
is "the last page" "" "$(next_page ghcr.io "$work/h3")"

echo "==> 6. which release directories may go"
got="$(printf '%s\n' git-aaa 1.0.0-a 1.0.1-b 1.1.0-dev.2-c 1.1.0-dev.3-d | prune_candidates 3 1.1.0-dev.3-d 1.1.0-dev.2-c | paste -sd' ' -)"
is "the oldest beyond three" "git-aaa 1.0.0-a" "$got"
got="$(printf '%s\n' git-aaa 1.0.0-a 1.0.1-b 1.1.0-dev.2-c | prune_candidates 3 git-aaa 1.0.0-a | paste -sd' ' -)"
is "never the current or the previous one, however old" "" "$got"
got="$(printf '%s\n' git-aaa 1.0.0-a 1.0.1-b 1.1.0-dev.2-c 2.0.0-held | prune_candidates 3 1.0.1-b 1.0.0-a | paste -sd' ' -)"
is "a held release fetched last counts as one of the three" "git-aaa" "$got"

echo "==> 7. upgraded_packages"
mkdir -p "$work/repo/compose"
cp -r "$REPO_ROOT/scripts" "$work/repo/"
printf 'DOMAIN=example.com\n' > "$work/repo/compose/.env"
cat > "$work/old.yml" <<'EOF'
services:
  app:
    image: fireflyiii/core:version-6.6.6@sha256:aaaa
  next:
    image: ghcr.io/majster01/firefly-pocket:sha-1111111
  db:
    image: postgres:17.11-alpine
EOF
cat > "$work/new.yml" <<'EOF'
services:
  app:
    image: fireflyiii/core:version-6.7.0@sha256:bbbb
  next:
    image: ghcr.io/majster01/firefly-pocket:sha-2222222
  db:
    image: postgres:17.11-alpine
  dozzle:
    image: amir20/dozzle:v8.0.0
EOF
got="$(bash -c 'source "$1/scripts/lib.sh" && upgraded_packages "$2" "$3"' _ "$work/repo" "$work/old.yml" "$work/new.yml" | paste -sd'|' -)"
is "what changed, as a person says it" "Firefly III 6.6.6 → 6.7.0|Firefly Pocket" "$got"
got="$(bash -c 'source "$1/scripts/lib.sh" && upgraded_packages "$2" "$2"' _ "$work/repo" "$work/old.yml")"
is "nothing changed: nothing" "" "$got"
got="$(bash -c 'source "$1/scripts/lib.sh" && upgraded_packages "$1/none.yml" "$2"' _ "$work/repo" "$work/new.yml")"
is "no compose file before: nothing" "" "$got"
cat > "$work/checkout.yml" <<'EOF'
services:
  app:
    image: fireflyiii/core:version-6.6.6
  db:
    image: postgres:17.11-alpine
EOF
cat > "$work/bundle.yml" <<'EOF'
services:
  app:
    image: fireflyiii/core:version-6.6.6@sha256:aaaa
  db:
    image: postgres:17.11-alpine@sha256:cccc
EOF
got="$(bash -c 'source "$1/scripts/lib.sh" && upgraded_packages "$2" "$3"' _ "$work/repo" "$work/checkout.yml" "$work/bundle.yml")"
is "a checkout's tag and the bundle's tag@digest are the same image" "" "$got"
sed 's/aaaa/bbbb/' "$work/bundle.yml" > "$work/bundle2.yml"
got="$(bash -c 'source "$1/scripts/lib.sh" && upgraded_packages "$2" "$3"' _ "$work/repo" "$work/bundle.yml" "$work/bundle2.yml")"
is "between two bundles, a new digest of a tag is a new build" "Firefly III" "$got"

echo "==> 8. the bundle's version"
r="$work/git"
git init -q -b master "$r"
c() { git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; }
c one; c two
is "before any release" 1.0.0-dev.2 "$(bundle_version "$r" HEAD)"
git -C "$r" tag v1.0.0
c three
is "after 1.0.0" 1.1.0-dev.1 "$(bundle_version "$r" HEAD)"
c four; c five
git -C "$r" tag v1.0.1
c six
is "a patch release does not start the count again" 1.1.0-dev.4 "$(bundle_version "$r" HEAD)"
git -C "$r" tag v1.1.0
c seven
is "a minor release starts the next line" 1.2.0-dev.1 "$(bundle_version "$r" HEAD)"
# make-bundle.sh, in a shallow clone of a repository that has it.
mkdir -p "$work/full"
cp -r "$REPO_ROOT/scripts" "$work/full/"
git -C "$work/full" init -q -b master
git -C "$work/full" add -A
git -C "$work/full" -c user.name=t -c user.email=t@t commit -q -m one
git -C "$work/full" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
git clone -q --depth 1 "file://$work/full" "$work/shallow"
if out="$("$work/shallow/scripts/make-bundle.sh" "$work/out" 2>&1)"; then
  fail "make-bundle.sh numbered a bundle in a shallow clone"
else
  [[ "$out" == *"shallow clone"* ]] && ok "make-bundle.sh refuses a shallow clone" || fail "make-bundle.sh failed otherwise: $out"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "FAILED: $failures"
  exit 1
fi
echo "all passed"
