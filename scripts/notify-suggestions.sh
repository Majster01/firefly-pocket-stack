#!/usr/bin/env bash
#
# The suggestions digest: one push to the Firefly Pocket app if category suggestions are
# waiting. Sends nothing when there are none. Run from cron every day; each
# device's settings in Pocket decide whether it gets today's (see crontab).

set -uo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

run_step "category suggestions reminder" \
  docker compose --project-directory "$COMPOSE_DIR" \
    run --rm --no-deps suggester notify
