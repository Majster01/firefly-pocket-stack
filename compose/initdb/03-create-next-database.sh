#!/bin/bash
# Firefly Pocket's own database (compose service `next`): its templates,
# profiles and push subscriptions. Owned by its own role, like the others, so
# no other app can read it.
#
# Idempotent on purpose. Postgres runs this automatically only on a brand-new
# db_data volume; on an existing server, scripts/setup-next-db.sh runs this
# same file inside the db container.
#
# The password is single-quoted, which is safe because gen-secrets.sh generates
# alphanumeric-only values.
set -euo pipefail

: "${NEXT_DB_PASSWORD:?NEXT_DB_PASSWORD is not set; run scripts/gen-secrets.sh}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
	DO \$\$
	BEGIN
	  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'next') THEN
	    CREATE ROLE next LOGIN PASSWORD '${NEXT_DB_PASSWORD}';
	  END IF;
	END
	\$\$;
	SELECT 'CREATE DATABASE firefly_next OWNER next'
	WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'firefly_next')\gexec
EOSQL
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname firefly_next <<-'EOSQL'
	GRANT ALL ON SCHEMA public TO next;
EOSQL
echo "initdb: database 'firefly_next' is ready"
