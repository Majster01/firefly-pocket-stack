#!/usr/bin/env bash
#
# Upgrade test (Release pipeline step 8): boot a published release bundle as a
# server running it would be, upgrade it to this checkout the way a deploy
# does, and check it again. CI runs it on every PR, from stable (what new
# installs run) and from latest (what your server runs, so the very upgrade
# the merge will cause there).
#
#     FROM=stable scripts/upgrade-test.sh     # the default
#     FROM=latest scripts/upgrade-test.sh
#     FROM=1.0.0  scripts/upgrade-test.sh
#
#   1. extract ghcr.io/majster01/firefly-pocket-stack:<FROM>; a tag that does
#      not exist yet (stable before the first release) passes, saying so
#   2. boot it with its own scripts/boot-test.sh, and leave it running: a
#      first user, a token, the old images and their data
#   3. carry its compose/.env over to this checkout, and let gen-secrets.sh
#      fill in any secret this version adds (README: re-run it on upgrades)
#   4. up -d --no-build --remove-orphans from this checkout, as the deploy does
#   5. the deploy's smoke test, and the token made on the old version against
#      Firefly III's API: the data came through
#
# Needs Docker. Never for the server: like boot-test.sh, it uses the server's
# names, and refuses where a compose/.env exists.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-ghcr.io/majster01/firefly-pocket-stack}"
from="${FROM:-stable}"
ENV_FILE="$REPO_ROOT/compose/.env"
cd "$REPO_ROOT"

if [ -f "$ENV_FILE" ]; then
  echo "FATAL: $ENV_FILE exists; run this in a fresh checkout, never on the server." >&2
  exit 1
fi

# 404 from the registry: no such tag yet. Anything else that is not 200 fails.
repo="${IMAGE#ghcr.io/}"
token="$(curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" | jq -r .token)"
code="$(curl -sS -o /dev/null -w '%{http_code}' --head -H "Authorization: Bearer $token" \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://ghcr.io/v2/$repo/manifests/$from")"
case "$code" in
  200) ;;
  404) echo "==> $IMAGE:$from does not exist yet: nothing to upgrade from, so nothing to test."; exit 0 ;;
  *) echo "FATAL: GHCR answered $code for $IMAGE:$from" >&2; exit 1 ;;
esac

old="$(mktemp -d)"
compose() { docker compose --project-directory "$REPO_ROOT/compose" "$@"; }
finish() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    echo "==> FAILED (exit $status). Services:"
    compose ps -a 2>/dev/null || docker ps -a
    for svc in $(compose config --services 2>/dev/null); do
      echo "---------------------------------------------------------------- $svc"
      compose logs --no-log-prefix --tail 60 "$svc" 2>&1 || true
    done
  fi
  if [ -f "$ENV_FILE" ]; then
    compose down -v --remove-orphans >/dev/null 2>&1 || true
  elif [ -f "$old/compose/.env" ]; then
    docker compose --project-directory "$old/compose" down -v --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -f "$ENV_FILE"
  rm -rf "$old"
  exit "$status"
}
trap finish EXIT

echo "==> $IMAGE:$from"
cid="$(docker create "$IMAGE:$from" none)"
docker cp -q "$cid:/." "$old/"
docker rm -f "$cid" >/dev/null
echo "    $(jq -r '"\(.version), built from \(.commit[0:7])"' "$old/release.json")"

echo "==> boot it, as a server running $from would be"
KEEP=1 "$old/scripts/boot-test.sh"

echo "==> upgrade to this checkout"
cp "$old/compose/.env" "$ENV_FILE"
scripts/gen-secrets.sh | sed -n '/Filled:/,/^$/p'
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
compose up -d --no-build --remove-orphans

echo "==> the deploy's smoke test"
smoke_test

echo "==> the token made on $from, against Firefly III's API"
printf 'header = "Authorization: Bearer %s"\n' "$IMPORTER_FIREFLY_TOKEN" \
  | docker run --rm -i --network "$DOCKER_NETWORK" "$CURL_IMAGE" \
      -fsS --max-time 30 --config - -H 'Accept: application/vnd.api+json' \
      -o /dev/null http://app:8080/api/v1/about/user
echo "Firefly III still knows the user and the token"

echo "==> upgraded from $from and checked"
