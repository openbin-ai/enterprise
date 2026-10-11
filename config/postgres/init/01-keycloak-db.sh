#!/bin/sh
# Runs once, on an empty data directory: Keycloak gets its own role and
# database next to the platform's. Idempotent on re-run of a fresh volume.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE ROLE keycloak LOGIN PASSWORD '${KEYCLOAK_DB_PASSWORD}';
CREATE DATABASE keycloak OWNER keycloak;
SQL
