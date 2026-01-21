#!/usr/bin/env bash
set -euo pipefail

stop_postgres_bounded() {
  set +e
  echo "Stopping postgres"

  # Ask postgres to stop
  if [[ -n "${PGDATA:-}" && -d "${PGDATA}" ]]; then
    PGPASSWORD="${SUPERUSER_PWD}" pg_ctl -D "${PGDATA}" -m fast stop >/dev/null 2>&1 || true
  fi

  return 0
}

trap_run() {
  local code=$?
  echo "critical failure (code=${code}), resetting database '${APP_DB_NAME}'..." >&2

  set +e

  # Provide app_db_name via --set and connect to a maintenance DB (postgres),
  # because you can't drop the DB you're connected to.
  PGPASSWORD="${SUPERUSER_PWD}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
    -d postgres -v ON_ERROR_STOP=1 \
    --set=app_db_name="${APP_DB_NAME}" --set=test_db_name="test" \
    >/dev/null 2>&1 <<'SQL'
REVOKE CONNECT ON DATABASE :"app_db_name" FROM PUBLIC;
REVOKE CONNECT ON DATABASE :"test_db_name" FROM PUBLIC;
REVOKE CONNECT ON DATABASE :"mae_db_name" FROM PUBLIC;

SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'mae_db_name'
  AND pid <> pg_backend_pid();

SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'app_db_name'
  AND pid <> pg_backend_pid();

SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'test_db_name'
  AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS :"app_db_name" CASCADE;
DROP DATABASE IF EXISTS :"test_db_name" CASCADE;
DROP DATABASE IF EXISTS :"mae_db_name" CASCADE;
CREATE DATABASE :"app_db_name";
CREATE DATABASE :"test_db_name";
CREATE DATABASE :"mae_db_name";
SQL

  stop_postgres_bounded

  echo "critical failure, waiting for container reload..." >&2
  while true; do sleep 1; done
}

# ERR trap requires errtrace to propagate through functions/subshells.
set -E
trap trap_run ERR

/workspace/scripts/run.sh
