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
#   1. extract ghcr.io/majster01/firefly-pocket-stack:<FROM> the way the server
#      agent does (scripts/agent.sh fetch); a tag that does not exist yet
#      (stable before the first release) passes, saying so
#   2. boot it with its own scripts/boot-test.sh, and leave it running: a
#      first user, a token, the old images and their data
#   3. carry its compose/.env over to this checkout, and its settings store
#      when it has one, and let gen-secrets.sh fill in any secret this version
#      adds (README: re-run it on upgrades)
#   4. up -d --no-build --remove-orphans from this checkout, as the deploy does
#   5. the deploy's smoke test, and the token made on the old version against
#      Firefly III's API and through Firefly Pocket's: the data came through
#   6. a server whose .env is still edited by hand: config import, as yours
#      runs it once, and up -d again, which must recreate nothing: every value
#      is still the same
#
# Needs Docker. Never for the server: like boot-test.sh, it uses the server's
# names, and refuses where a compose/.env exists.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-ghcr.io/majster01/firefly-pocket-stack}"
from="${FROM:-stable}"
ENV_FILE="$REPO_ROOT/compose/.env"
STORE=(compose/config.json compose/secrets/env compose/.env.rendered)
cd "$REPO_ROOT"

if [ -f "$ENV_FILE" ] || [ -e compose/config.json ] || [ -e compose/secrets/env ]; then
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
  rm -rf "$ENV_FILE" "${STORE[@]}" compose/.env.before-import
  rm -rf "$old"
  exit "$status"
}
trap finish EXIT

echo "==> $IMAGE:$from"
# As the server agent fetches it: each piece checked against its digest.
IMAGE="$IMAGE" "$REPO_ROOT/scripts/agent.sh" fetch "$from" "$old"

echo "==> boot it, as a server running $from would be"
KEEP=1 "$old/scripts/boot-test.sh"

echo "==> upgrade to this checkout"
cp "$old/compose/.env" "$ENV_FILE"
carried=""
if [ -f "$old/compose/config.json" ]; then
  cp -a "$old/compose/config.json" "$old/compose/.env.rendered" compose/
  cp -a "$old/compose/secrets/env" compose/secrets/
  carried=1
fi
scripts/gen-secrets.sh | sed -n '/Filled:/,/^$/p'
# As the deploy starts: .env written from the store, for this version's settings.
[ -z "$carried" ] || scripts/firefly-pocket config render
# shellcheck source=lib.sh
source "$REPO_ROOT/scripts/lib.sh"
compose up -d --no-build --remove-orphans

echo "==> the deploy's smoke test"
smoke_test

echo "==> the token made on $from, against Firefly III's API and through Firefly Pocket's"
token_check "$IMPORTER_FIREFLY_TOKEN"

if [ -z "$carried" ]; then
  echo "==> its hand-edited .env into the settings store, as your server does it once"
  scripts/firefly-pocket config import
  went="$(compose up -d --no-build --remove-orphans 2>&1)"
  if grep -E 'Recreate|Creat' <<<"$went"; then
    echo "the import changed what a service runs with: it recreated the services above"
    exit 1
  fi
  smoke_test
  echo "every service runs on as it was"
fi

echo "==> upgraded from $from and checked"
