#!/bin/bash
# Creates Firefly III's database, owned by its own least-privilege role. The
# importer's and Firefly Pocket's come from 02- and 03-, the same way, so no
# app can read another's data.
#
# IMPORTANT: Postgres runs /docker-entrypoint-initdb.d scripts ONLY on the
# very first start against an empty data directory. Editing this file later
# has no effect on an existing `db_data` volume — you would have to apply the
# change by hand with psql.
#
# Passwords are single-quoted below, which is safe because gen-secrets.sh
# generates alphanumeric-only values. Do not hand-edit them to include quotes.

set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
	CREATE ROLE firefly LOGIN PASSWORD '${FIREFLY_DB_PASSWORD}';
	CREATE DATABASE firefly OWNER firefly;
EOSQL

# Laravel needs to create objects in the public schema; on Postgres 15+ the
# public schema is no longer writable by default for non-owners.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname firefly <<-'EOSQL'
	GRANT ALL ON SCHEMA public TO firefly;
EOSQL

echo "initdb: created database 'firefly'"
