#!/usr/bin/env bash
#
# Create the importer fork's database on an EXISTING server. A fresh install
# gets it from compose/initdb automatically; Postgres skips initdb scripts on
# a db_data volume that already holds data, which is why this exists.
#
#     ./scripts/gen-secrets.sh          # adds IMPORTER_DB_PASSWORD if missing
#     ./scripts/setup-importer-db.sh
#
# Safe to run any number of times.

set -euo pipefail

# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

: "${IMPORTER_DB_PASSWORD:?IMPORTER_DB_PASSWORD is not set; run scripts/gen-secrets.sh}"

docker compose --project-directory "$COMPOSE_DIR" exec -T \
  -e IMPORTER_DB_PASSWORD="$IMPORTER_DB_PASSWORD" db \
  bash /docker-entrypoint-initdb.d/02-create-importer-database.sh
