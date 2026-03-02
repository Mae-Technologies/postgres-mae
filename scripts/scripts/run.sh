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

  # Use localhost since we are inside the postgres-mae container
  export DATABASE_URL="postgres://${MIGRATOR_USER}:${MIGRATOR_PWD}@127.0.0.1:${DB_PORT}/${DB}"

  echo "▶ Migrating ${DB} from ${MIGRATION_DIR}..."
  sqlx migrate run --source "$MIGRATION_DIR"
  echo "  ✓ ${DB} migrated"
done
