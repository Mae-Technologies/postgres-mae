#!/usr/bin/env bash
set -euo pipefail

SERVICES=(
  "ru_accounting_service:/workspace/migrations/accounting"
  "ru_widget_service:/workspace/migrations/widget"
  "ru_api_service:/workspace/migrations/api"
)

for entry in "${SERVICES[@]}"; do
  DB="${entry%%:*}"
  MIGRATION_DIR="${entry##*:}"

  if [ ! -d "$MIGRATION_DIR" ]; then
    echo "  ⚠ No migrations dir at ${MIGRATION_DIR}, skipping ${DB}"
    continue
  fi

  # Use localhost since we are inside the postgres-mae container.
  #
  # IMPORTANT: Run service migrations as SUPERUSER so that the DDL blocker
  # (mae._block_disallowed_ddl in 000700_block_disallowed_ddl.sql) sees the
  # effective role as "postgres". The event trigger only allows CREATE/ALTER
  # DDL for app_owner/postgres (with a narrow exception for _sqlx_migrations
  # bookkeeping tables). Using MIGRATOR_USER here causes new raw DDL in
  # service migrations to be rejected on existing volumes.
  export DATABASE_URL="postgres://${SUPERUSER}:${SUPERUSER_PWD}@127.0.0.1:${DB_PORT}/${DB}"

  echo "▶ Migrating ${DB} from ${MIGRATION_DIR}..."
  sqlx migrate run --source "$MIGRATION_DIR"
  echo "  ✓ ${DB} migrated"
done
