#!/usr/bin/env bash
#
# Create Firefly Pocket's database on an EXISTING server. A fresh install gets it
# from compose/initdb automatically; Postgres skips initdb scripts on a db_data
# volume that already holds data, which is why this exists.
#
#     ./scripts/gen-secrets.sh          # adds NEXT_DB_PASSWORD if missing
#     ./scripts/setup-next-db.sh
#
# Safe to run any number of times.

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

: "${NEXT_DB_PASSWORD:?NEXT_DB_PASSWORD is not set; run scripts/gen-secrets.sh}"

docker compose --project-directory "$COMPOSE_DIR" exec -T \
  -e NEXT_DB_PASSWORD="$NEXT_DB_PASSWORD" db \
  bash /docker-entrypoint-initdb.d/03-create-next-database.sh
