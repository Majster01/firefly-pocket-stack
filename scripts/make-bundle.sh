#!/usr/bin/env bash
#
# Assemble the release bundle (Release pipeline step 5): the files a server
# runs, taken from git, with every image in compose pinned to the digest its
# tag names right now, and a release.json that says what is in it.
# .github/workflows/publish.yml pushes the result, on every merge into master,
# as ghcr.io/majster01/firefly-pocket-stack: an image FROM scratch holding just
# these files. CI assembles one on every PR without pushing it.
#
#     scripts/make-bundle.sh <out-dir> [<revision>]     # revision: default HEAD
#
# Needs the history back to the last release tag (it numbers the version),
# docker buildx (it reads digests from the registries, anonymously) and docker
# compose (it checks the result).
#
# The files keep their paths in this repository, so a server can diff a bundle
# against a checkout (Server agent step 1). Only the image lines differ.
#
# Versions: a master build is numbered after the next minor, so after v1.4.2
# it is 1.5.0-dev.<n>, <n> being the commits on master since that tag, and it
# sorts after 1.4.2 and before 1.5.0. Before the first release, 1.0.0-dev.<n>.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-}"
rev="${2:-HEAD}"
if [ -z "$out" ]; then
  echo "usage: $0 <out-dir> [<revision>]" >&2
  exit 2
fi
if [ -e "$out" ] && [ -n "$(ls -A "$out")" ]; then
  echo "FATAL: $out is not empty." >&2
  exit 1
fi
git() { command git -C "$REPO_ROOT" "$@"; }
commit="$(git rev-parse --verify "$rev^{commit}")"

# Everything a server reads, and nothing it does not: no CI, Terraform, docs or
# the suggester's source (its image is in the bundle by digest).
PATHS=(
  LICENSE crontab scripts config
  compose/docker-compose.yml compose/Caddyfile compose/.env.example
  compose/initdb compose/legal compose/secrets compose/importer
)
mkdir -p "$out"
git archive "$commit" -- "${PATHS[@]}" | tar -x -C "$out"

# ------------------------------------------------------------------ version ---
last="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "$commit" 2>/dev/null || true)"
if [ -n "$last" ]; then
  IFS=. read -r major minor _ <<<"${last#v}"
  version="$major.$((minor + 1)).0-dev.$(git rev-list --count --first-parent "$last..$commit")"
else
  version="1.0.0-dev.$(git rev-list --count --first-parent "$commit")"
fi

# ------------------------------------------------------------------ digests ---
# digest_of <image:tag>: the digest the tag names now; for a multi-platform
# image the index's, so it pulls on any platform. A registry that answers 429
# (Docker Hub limits anonymous requests) gets three more tries.
digest_of() {
  local ref="$1" attempt d
  for attempt in 1 2 3 4; do
    d="$(docker buildx imagetools inspect "$ref" 2>/dev/null | awk '$1 == "Digest:" { print $2; exit }')" || true
    if [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]]; then
      echo "$d"
      return 0
    fi
    [ "$attempt" -lt 4 ] && sleep $((attempt * 15))
  done
  docker buildx imagetools inspect "$ref" >/dev/null || true   # says why, on stderr
  return 1
}

compose="$out/compose/docker-compose.yml"
images="$(sed -nE 's/^[[:space:]]+image:[[:space:]]+([^[:space:]#]+).*/\1/p' "$compose" | sort -u)"
for ref in $images; do
  case "$ref" in
    *@*) echo "FATAL: $ref is pinned by digest already; compose names images by tag." >&2; exit 1 ;;
  esac
  if ! digest="$(digest_of "$ref")"; then
    echo "FATAL: no digest for $ref" >&2
    exit 1
  fi
  REF="$ref" DIGEST="$digest" perl -pi -e 's#^(\s+image:\s+)\Q$ENV{REF}\E(?=\s|$)#$1$ENV{REF}\@$ENV{DIGEST}#' "$compose"
  echo "    $ref@$digest"
done

# -------------------------------------------------------------- release.json ---
migrating="$(sed -nE 's/^MIGRATING="([^"]*)"$/\1/p' "$out/scripts/lib.sh")"
[ -n "$migrating" ] || { echo "FATAL: no MIGRATING line in scripts/lib.sh" >&2; exit 1; }
# "<service> <image>" for each service with an image line (lib.sh's compose_images).
awk '
  /^services:/ { in_services = 1; next }
  in_services && /^[^ #]/ { in_services = 0 }
  in_services && /^  [a-z][a-z0-9_-]*:[[:space:]]*$/ { svc = $1; sub(/:$/, "", svc); next }
  in_services && svc != "" && /^    image:[[:space:]]/ { print svc, $2 }' "$compose" \
| jq -R -s \
    --arg version "$version" --arg commit "$commit" \
    --arg created "$(git show -s --format=%cI "$commit")" \
    --arg migrating "$migrating" '
  ($migrating | split(" ")) as $m
  | {
      schema: 1,
      version: $version,
      commit: $commit,
      created: $created,
      source: "https://github.com/Majster01/firefly-pocket-stack",
      components: [
        split("\n")[] | select(length > 0) | split(" ") as [$service, $ref]
        | ($ref | split("@")) as [$named, $digest]
        | ($named | capture("^(?<image>.+):(?<tag>[^:/]+)$")) as $n
        | { service: $service, image: $n.image, tag: $n.tag, digest: $digest,
            migrates: ($m | any(. == $service)) }
      ]
    }' > "$out/release.json"

# -------------------------------------------------------------------- check ---
# Every image is pinned, and compose still accepts the file: on a copy, with a
# throwaway .env, so nothing of it lands in the bundle.
unpinned="$(grep -nE '^[[:space:]]+image:' "$compose" | grep -v '@sha256:' || true)"
if [ -n "$unpinned" ]; then
  echo "FATAL: image lines without a digest:" >&2
  echo "$unpinned" >&2
  exit 1
fi
check="$(mktemp -d)"
trap 'rm -rf "$check"' EXIT
cp -a "$out/." "$check/"
cp "$check/compose/.env.example" "$check/compose/.env"
# A placeholder hash, so gen-secrets.sh does not start a container for one.
sed -i 's/^IMPORT_AUTH_HASH=$/IMPORT_AUTH_HASH=placeholder/' "$check/compose/.env"
"$check/scripts/gen-secrets.sh" >/dev/null
docker compose --project-directory "$check/compose" config -q

echo "==> bundle $version ($(git rev-parse --short "$commit")) in $out: $(jq '.components | length' "$out/release.json") components"
