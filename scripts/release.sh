#!/usr/bin/env bash
#
# Release a commit of master (Release pipeline step 6). .github/workflows/release.yml
# runs it by hand; it rebuilds nothing:
#
#   1. the version: the last release (vX.Y.Z tag) bumped by <bump>; the first
#      release is 1.0.0
#   2. the commit's published bundle, ghcr.io/majster01/firefly-pocket-stack:
#      sha-<commit>, gets the tags X.Y.Z, X.Y and stable, by digest: stable is
#      the very bundle that ran as latest
#   3. the git tag vX.Y.Z, and a GitHub release that lists the components,
#      read from the bundle's own release.json, and the changes
#
#     scripts/release.sh <patch|minor|major> [<commit>]   # commit: default master's head
#     DRY_RUN=1 scripts/release.sh minor                  # says what it would do, changes nothing
#
# Bumps say what the person running a server must do: major, act (a value only
# they can give, a Postgres major, a hostname change); minor, nothing,
# migrations included; patch, fixes only.
#
# Needs the history with tags, docker buildx logged in to ghcr.io with push
# rights, and gh logged in with contents: write. A dry run needs neither login.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-ghcr.io/majster01/firefly-pocket-stack}"
bump="${1:-}"
case "$bump" in
  patch|minor|major) ;;
  *) echo "usage: $0 patch|minor|major [<commit>]" >&2; exit 2 ;;
esac
git() { command git -C "$REPO_ROOT" "$@"; }
dry() { [ "${DRY_RUN:-}" = 1 ]; }

git fetch -q --tags origin master
commit="$(git rev-parse --verify "${2:-origin/master}^{commit}")"
short="${commit:0:7}"
if ! git merge-base --is-ancestor "$commit" origin/master; then
  echo "FATAL: $short is not on master." >&2
  exit 1
fi

# ------------------------------------------------------------------ version ---
last="$(git tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n 1)"
if [ -z "$last" ]; then
  version=1.0.0
  echo "==> first release: $version (the bump, $bump, starts from nothing)"
else
  if ! git merge-base --is-ancestor "$last" "$commit"; then
    echo "FATAL: $short is older than $last; a release only moves stable forward." >&2
    exit 1
  fi
  if [ "$(git rev-parse "$last^{commit}")" = "$commit" ]; then
    echo "FATAL: $short is $last already." >&2
    exit 1
  fi
  IFS=. read -r major minor patch <<<"${last#v}"
  case "$bump" in
    major) version="$((major + 1)).0.0" ;;
    minor) version="$major.$((minor + 1)).0" ;;
    patch) version="$major.$minor.$((patch + 1))" ;;
  esac
  echo "==> $last -> $version ($bump)"
fi
line="${version%.*}"

# ------------------------------------------------------------------- bundle ---
digest_of() {
  docker buildx imagetools inspect "$1" 2>/dev/null | awk '$1 == "Digest:" { print $2; exit }'
}
digest="$(digest_of "$IMAGE:sha-$short" || true)"
if ! [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "FATAL: no bundle $IMAGE:sha-$short. Publish bundle has not pushed one for $short (yet)." >&2
  exit 1
fi
echo "    bundle $IMAGE:sha-$short = $digest"

# The release.json inside the bundle: what is actually being released.
work="$(mktemp -d)"
trap 'rm -rf "$work"; docker rm -f "release-$short" >/dev/null 2>&1 || true' EXIT
docker create --name "release-$short" "$IMAGE@$digest" none >/dev/null
docker cp "release-$short:/release.json" "$work/release.json"
build="$(jq -r .version "$work/release.json")"
[ "$(jq -r .commit "$work/release.json")" = "$commit" ] || {
  echo "FATAL: the bundle's release.json names another commit." >&2
  exit 1
}

# -------------------------------------------------------------------- notes ---
{
  echo "Bundle \`$IMAGE:$version\` (\`$digest\`), the build \`$build\` of $short."
  echo
  echo "| Service | Image | Tag | Migrates a database |"
  echo "| --- | --- | --- | --- |"
  jq -r '.components[] | "| \(.service) | `\(.image)` | `\(.tag)` | \(if .migrates then "yes" else "" end) |"' "$work/release.json"
  echo
  if [ -n "$last" ]; then
    echo "## Changes since $last"
    range="$last..$commit"
  else
    echo "## Changes"
    range="$commit"
  fi
  echo
  git log --first-parent --format='- %s' "$range"
} > "$work/notes.md"

if dry; then
  echo "==> DRY_RUN: would tag $IMAGE@$digest as $version, $line and stable, push v$version on $short, and publish:"
  echo
  cat "$work/notes.md"
  exit 0
fi

# -------------------------------------------------------------------- tags ---
# --prefer-index=false: the same manifest under more tags, so every tag has the
# bundle's own digest (without it, buildx wraps it in a new index).
docker buildx imagetools create --prefer-index=false \
  -t "$IMAGE:$version" -t "$IMAGE:$line" -t "$IMAGE:stable" "$IMAGE@$digest"
for tag in "$version" "$line" stable; do
  got="$(digest_of "$IMAGE:$tag")"
  if [ "$got" != "$digest" ]; then
    echo "FATAL: $IMAGE:$tag is $got, not $digest." >&2
    exit 1
  fi
done
echo "    $version, $line and stable = $digest"

git tag -a "v$version" "$commit" -m "firefly-pocket-stack $version"
git push -q origin "refs/tags/v$version"
gh release create "v$version" --verify-tag --title "$version" --notes-file "$work/notes.md"
echo "==> released $version: $(gh release view "v$version" --json url --jq .url)"
