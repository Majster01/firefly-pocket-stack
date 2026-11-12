#!/usr/bin/env bash
#
# Release a commit of master (Release pipeline step 6). .github/workflows/release.yml
# runs it by hand; it rebuilds nothing:
#
#   1. the version: the last release (vX.Y.Z tag) bumped by <bump>; the first
#      release is 1.0.0
#   2. the canary gate: only a commit your server has run, with a successful
#      deploy, for 24 hours (Release pipeline step 7)
#   3. the commit's published bundle, ghcr.io/majster01/firefly-pocket-stack:
#      sha-<commit>, with the signature Publish bundle gave it on master
#      (Release pipeline step 9)
#   4. that bundle gets the tags X.Y.Z and stable, by digest: stable is the
#      very bundle that ran as latest, and carries the same signature. Servers
#      follow latest, stable or an exact X.Y.Z (scripts/deploy.sh); there is no
#      X.Y tag, as only master is released and a line would stop at the next minor
#   5. the git tag vX.Y.Z, and a GitHub release that lists the components,
#      read from the bundle's own release.json, and the changes
#
#     scripts/release.sh <patch|minor|major> [<commit>]   # commit: default master's head
#     DRY_RUN=1 scripts/release.sh minor                  # says what it would do, changes nothing
#     SKIP_CANARY=1 scripts/release.sh patch              # an urgent fix: no 24 hours on the server
#
# Bumps say what the person running a server must do: major, act (a value only
# they can give, a Postgres major, a hostname change); minor, nothing,
# migrations included; patch, fixes only.
#
# Needs the history with tags, gh logged in (it reads the commit's statuses;
# for a release, contents: write), cosign, and docker buildx logged in to
# ghcr.io with push rights (not for a dry run).

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

# -------------------------------------------------------------- canary gate ---
# Your server is the canary. The evidence is the deploy/server status deploy.sh
# sets on every commit it deploys (DEPLOY_STATUS_TOKEN in the server's .env,
# README "Deploying"). The newest must be success, and the time counts from the
# first success since the last failure: a deploy --force of the same commit
# does not restart the clock, a failed deploy does.
canary_hours="${CANARY_HOURS:-24}"
if [ "${SKIP_CANARY:-}" = 1 ]; then
  echo "==> SKIP_CANARY: released without $canary_hours hours on your server"
  canary="Released without the $canary_hours-hour canary on the server."
else
  statuses="$(gh api "repos/{owner}/{repo}/commits/$commit/statuses?per_page=100" \
    --jq '[.[] | select(.context == "deploy/server")] | sort_by(.created_at)')"
  newest="$(jq -r 'last // {} | "\(.state // "none") \(.description // "")"' <<<"$statuses")"
  if [ "${newest%% *}" = none ]; then
    echo "FATAL: $short has no deploy/server status: your server has not reported deploying it." >&2
    echo "       Is DEPLOY_STATUS_TOKEN in the server's .env, with Commit statuses: write on this repository?" >&2
    exit 1
  fi
  if [ "${newest%% *}" != success ]; then
    echo "FATAL: $short's newest deploy/server status is ${newest%% *}: ${newest#* }" >&2
    exit 1
  fi
  since="$(jq -r 'reduce .[] as $s (null;
      if $s.state == "success" then (. // $s.created_at)
      elif $s.state == "pending" then .
      else null end)' <<<"$statuses")"
  ran=$(( ( $(date -u +%s) - $(date -u -d "$since" +%s) ) / 3600 ))
  if [ "$ran" -lt "$canary_hours" ]; then
    echo "FATAL: $short has run on your server for ${ran}h (since $since); a release needs ${canary_hours}h." >&2
    echo "       It can be released after $(date -u -d "$since + $canary_hours hours" '+%Y-%m-%d %H:%M UTC'), or pick an older commit." >&2
    exit 1
  fi
  echo "==> canary: $short has run on your server since $since (${ran}h)"
  canary="Ran on the canary server since $since."
fi

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
work="$(mktemp -d)"
trap 'rm -rf "$work"; docker rm -f "release-$short" >/dev/null 2>&1 || true' EXIT

# Signed by Publish bundle on master, keyless: the certificate names the
# workflow, and Sigstore's transparency log holds the signing. A bundle made
# anywhere else, or pushed before signing began, is refused.
repo="$(gh api 'repos/{owner}/{repo}' --jq .full_name)"
identity="https://github.com/$repo/.github/workflows/publish.yml@refs/heads/master"
issuer=https://token.actions.githubusercontent.com
if ! cosign verify "$IMAGE@$digest" --certificate-identity "$identity" \
    --certificate-oidc-issuer "$issuer" >/dev/null 2>"$work/cosign.log"; then
  echo "FATAL: the bundle of $short has no valid signature from $identity:" >&2
  sed 's/^/       /' "$work/cosign.log" >&2
  exit 1
fi
echo "    signed by $identity"

# The release.json inside the bundle: what is actually being released.
docker create --name "release-$short" "$IMAGE@$digest" none >/dev/null
docker cp "release-$short:/release.json" "$work/release.json"
build="$(jq -r .version "$work/release.json")"
[ "$(jq -r .commit "$work/release.json")" = "$commit" ] || {
  echo "FATAL: the bundle's release.json names another commit." >&2
  exit 1
}

# -------------------------------------------------------------------- notes ---
{
  echo "Bundle \`$IMAGE:$version\` (\`$digest\`), the build \`$build\` of $short. $canary"
  echo
  echo "Signed by Publish bundle on master. To check it:"
  echo
  echo '```'
  echo "cosign verify $IMAGE:$version \\"
  echo "  --certificate-identity $identity \\"
  echo "  --certificate-oidc-issuer $issuer"
  echo '```'
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
  echo "==> DRY_RUN: would tag $IMAGE@$digest as $version and stable, push v$version on $short, and publish:"
  echo
  cat "$work/notes.md"
  exit 0
fi

# -------------------------------------------------------------------- tags ---
# --prefer-index=false: the same manifest under more tags, so every tag has the
# bundle's own digest (without it, buildx wraps it in a new index).
docker buildx imagetools create --prefer-index=false \
  -t "$IMAGE:$version" -t "$IMAGE:stable" "$IMAGE@$digest"
for tag in "$version" stable; do
  got="$(digest_of "$IMAGE:$tag")"
  if [ "$got" != "$digest" ]; then
    echo "FATAL: $IMAGE:$tag is $got, not $digest." >&2
    exit 1
  fi
done
echo "    $version and stable = $digest"

git tag -a "v$version" "$commit" -m "firefly-pocket-stack $version"
git push -q origin "refs/tags/v$version"
gh release create "v$version" --verify-tag --title "$version" --notes-file "$work/notes.md"
echo "==> released $version: $(gh release view "v$version" --json url --jq .url)"
