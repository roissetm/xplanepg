#!/bin/bash
set -e

echo "==> Installing XplanePLPG..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS dblink;
EOSQL

for f in \
    /opt/xplaneplpg/sql/00_schema_provider.sql \
    /opt/xplaneplpg/sql/01_helpers.sql \
    /opt/xplaneplpg/sql/02_actions.sql \
    /opt/xplaneplpg/sql/03_reconciler.sql; do
    echo "  Loading $f..."
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f "$f"
done

echo "==> XplanePLPG installed successfully"
