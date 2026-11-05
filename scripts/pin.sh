#!/usr/bin/env bash
#
# Point a fork's service at another image tag, and commit the change. Merging
# into master is deploying, so this is how a fork gets deployed:
# .github/workflows/pin.yml runs it when the fork's CI has pushed an image. By
# hand it is a rollback (then push):
#
#     scripts/pin.sh next sha-abc1234          # ghcr.io/majster01/firefly-pocket-next
#     scripts/pin.sh importer 2.3.5-abc1234    # ghcr.io/majster01/data-importer
#
# Refuses a tag that GHCR does not serve without a login: the server pulls
# anonymously, so the fork's package must be public.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/compose/docker-compose.yml"

case "${1:-}" in
  next)     name=Next     image=ghcr.io/majster01/firefly-pocket-next source=Majster01/firefly-pocket ;;
  importer) name=importer image=ghcr.io/majster01/data-importer      source=Majster01/data-importer ;;
  *) echo "usage: $0 next|importer <tag>" >&2; exit 2 ;;
esac
tag="${2:-}"
if ! [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
  echo "FATAL: '$tag' is not an image tag." >&2
  exit 2
fi

current="$(sed -nE "s#^[[:space:]]*image: $image:([^[:space:]]+).*#\1#p" "$COMPOSE_FILE")"
if [ -z "$current" ]; then
  echo "FATAL: no 'image: $image:<tag>' line in docker-compose.yml." >&2
  exit 1
fi
if [ "$current" = "$tag" ]; then
  echo "==> $name is already at $tag"
  exit 0
fi
if [ -n "$(git -C "$REPO_ROOT" status --porcelain -- "$COMPOSE_FILE")" ]; then
  echo "FATAL: compose/docker-compose.yml has uncommitted changes." >&2
  exit 1
fi

# The registry API directly, anonymously, as the server will pull it. A missing
# tag is a 404; a private (or missing) package is refused at the token.
repo="${image#ghcr.io/}"
token="$(curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" 2>/dev/null \
  | sed -nE 's/.*"token":"([^"]+)".*/\1/p')" || true
if ! curl -fsS -o /dev/null --head -H "Authorization: Bearer ${token:-none}" \
     -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json' \
     "https://ghcr.io/v2/$repo/manifests/$tag" 2>/dev/null; then
  echo "FATAL: $image:$tag cannot be pulled without a login: not pushed (yet), or the package is private." >&2
  exit 1
fi

echo "==> $name $current -> $tag"
export IMAGE="$image" TAG="$tag"
perl -pi -e 's#^(\s*image: \Q$ENV{IMAGE}\E:)\S+#$1$ENV{TAG}#' "$COMPOSE_FILE"

commit="${tag##*-}"   # sha-abc1234 / 2.3.5-abc1234 -> abc1234
git -C "$REPO_ROOT" commit -q -F - -- "$COMPOSE_FILE" <<EOF
Bump $name to ${tag#sha-}

$image:$tag, built from https://github.com/$source/commit/$commit
EOF
echo "    committed: $(git -C "$REPO_ROOT" log --oneline -1)"
