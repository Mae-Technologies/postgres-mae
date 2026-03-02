#!/usr/bin/env bash
set -euo pipefail

PSQL="psql -U ${SUPERUSER} -h 127.0.0.1 -p ${DB_PORT}"

echo "▶ Creating roles..."

$PSQL -c "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${MIGRATOR_USER}') THEN
    CREATE ROLE ${MIGRATOR_USER} LOGIN PASSWORD '${MIGRATOR_PWD}';
  END IF;
END \$\$;"

$PSQL -c "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_USER}') THEN
    CREATE ROLE ${APP_USER} LOGIN PASSWORD '${APP_USER_PWD}';
  END IF;
END \$\$;"

$PSQL -c "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${TABLE_PROVISIONER_USER}') THEN
    CREATE ROLE ${TABLE_PROVISIONER_USER} LOGIN PASSWORD '${TABLE_PROVISIONER_PWD}';
  END IF;
END \$\$;"

echo "▶ Creating databases + privileges..."

for DB in ru_accounting_service ru_widget_service ru_api_service; do
  $PSQL -c "SELECT 1 FROM pg_database WHERE datname = '${DB}'" | grep -q 1 || \
    $PSQL -c "CREATE DATABASE ${DB} OWNER ${SUPERUSER};"

  # Migrator gets full access for sqlx migrations
  $PSQL -d "$DB" -c "GRANT ALL PRIVILEGES ON DATABASE ${DB} TO ${MIGRATOR_USER};"
  $PSQL -d "$DB" -c "GRANT ALL ON SCHEMA public TO ${MIGRATOR_USER};"
  $PSQL -d "$DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${MIGRATOR_USER};"
  $PSQL -d "$DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${MIGRATOR_USER};"

  # App user gets DML
  $PSQL -d "$DB" -c "GRANT CONNECT ON DATABASE ${DB} TO ${APP_USER};"
  $PSQL -d "$DB" -c "GRANT USAGE ON SCHEMA public TO ${APP_USER};"
  $PSQL -d "$DB" -c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${APP_USER};"
  $PSQL -d "$DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${APP_USER};"
  $PSQL -d "$DB" -c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${APP_USER};"
  $PSQL -d "$DB" -c "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ${APP_USER};"

  # Table provisioner
  $PSQL -d "$DB" -c "GRANT CONNECT ON DATABASE ${DB} TO ${TABLE_PROVISIONER_USER};"
  $PSQL -d "$DB" -c "GRANT USAGE ON SCHEMA public TO ${TABLE_PROVISIONER_USER};"

  echo "  ✓ ${DB}"
done
