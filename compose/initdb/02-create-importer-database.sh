#!/bin/bash
# The Data Importer fork's own database: bank connections, their accounts and
# import results (docs/design/bank-link.md). Owned by its own role, like the
# others, so neither Firefly III nor Firefly Pocket can read the bank sessions.
#
# Idempotent on purpose. Postgres runs this automatically only on a brand-new
# db_data volume; on an existing server, scripts/setup-importer-db.sh runs this
# same file inside the db container.
#
# The password is single-quoted, which is safe because gen-secrets.sh generates
# alphanumeric-only values.
set -euo pipefail

: "${IMPORTER_DB_PASSWORD:?IMPORTER_DB_PASSWORD is not set; run scripts/gen-secrets.sh}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
	DO \$\$
	BEGIN
	  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'importer') THEN
	    CREATE ROLE importer LOGIN PASSWORD '${IMPORTER_DB_PASSWORD}';
	  END IF;
	END
	\$\$;
	SELECT 'CREATE DATABASE fireflyx_importer OWNER importer'
	WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'fireflyx_importer')\gexec
EOSQL
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname fireflyx_importer <<-'EOSQL'
	GRANT ALL ON SCHEMA public TO importer;
EOSQL
echo "initdb: database 'fireflyx_importer' is ready"
