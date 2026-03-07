#!/usr/bin/env bash
set -euo pipefail

stop_postgres_bounded() {
  set +e
  echo "Stopping postgres"
  if [[ -n "${PGDATA:-}" && -d "${PGDATA}" ]]; then
    PGPASSWORD="${SUPERUSER_PWD}" pg_ctl -D "${PGDATA}" -m fast stop >/dev/null 2>&1 || true
  fi
  return 0
}

trap_run() {
  local code=$?
  echo "critical failure (code=${code}), resetting databases..." >&2
  set +e

  # Resolve database list for reset
  if [[ -n "${PG_MAE_DATABASES:-}" ]]; then
    IFS=',' read -ra _reset_dbs <<< "${PG_MAE_DATABASES}"
  else
    _reset_dbs=("${APP_DB_NAME:-postgres}")
  fi

  # Revoke connections and drop/recreate each database
  for _raw_db in "${_reset_dbs[@]}"; do
    _db="$(echo "${_raw_db}" | xargs)"
    PGPASSWORD="${SUPERUSER_PWD}" psql \
      -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
      -d postgres -v ON_ERROR_STOP=1 \
      --set=target_db="${_db}" \
      >/dev/null 2>&1 <<'SQL'
REVOKE CONNECT ON DATABASE :"target_db" FROM PUBLIC;
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'target_db' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS :"target_db";
CREATE DATABASE :"target_db";
SQL
  done

  stop_postgres_bounded

  echo "critical failure, waiting for container reload..." >&2
  while true; do sleep 1; done
}

set -E
trap trap_run ERR

/workspace/scripts/run.sh
