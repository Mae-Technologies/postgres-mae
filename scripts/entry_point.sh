#!/usr/bin/env bash
# scripts/entry_point.sh
#
# Container entrypoint orchestrator:
#   1. Starts postgres and runs migrations (via scripts/run.sh)
#   2. Runs pgTAP tests as a separate lifecycle step (via scripts/run_tests.sh) — Issue #14
#   3. In operational (non-test) mode: waits on the postgres process and streams
#      logs if it exits unexpectedly — Issue #17 (wait block is the final step)

set -euo pipefail

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
c_reset="\033[0m"
c_blue="\033[34m"
c_green="\033[32m"
c_yellow="\033[33m"
c_red="\033[31m"

log() { echo -e "${c_blue}$*${c_reset}"; }
log_ok()  { echo -e "${c_green}📟${c_reset} $*"; }
log_warn(){ echo -e "${c_yellow}😶${c_reset} $*"; }
log_err() { echo -e "${c_red}🔥${c_reset} $*" >&2; }

# -----------------------------------------------------------------------------
# Load .env early so this script can branch on APP_ENV and access SUPERUSER_PWD
# in the error trap. Runtime overrides already in the environment take precedence.
# -----------------------------------------------------------------------------
export ENV_PATH="${ENV_PATH:-/workspace/.env}"
if [[ ! -f "${ENV_PATH}" ]]; then
  log_err "ENV_PATH not found: ${ENV_PATH}"
  exit 1
fi

# Preserve any runtime overrides before sourcing
_ep_vars=(APP_ENV DB_HOST DB_PORT APP_DB_NAME SUPERUSER SUPERUSER_PWD APP_DB_NAME)
declare -A _ep_saved=()
for _v in "${_ep_vars[@]}"; do
  if [[ -n "${!_v+x}" ]]; then
    _ep_saved["${_v}"]="${!_v}"
  fi
done

set -a
# shellcheck disable=SC1090
source "${ENV_PATH}"
set +a

# Restore runtime overrides
for _v in "${_ep_vars[@]}"; do
  if [[ -n "${_ep_saved[${_v}]+x}" ]]; then
    export "${_v}=${_ep_saved[${_v}]}"
  fi
done

# Issue #12/#21: default DB_PORT to 5432 so callers can override via environment
: "${DB_PORT:=5432}"
export DB_PORT

app_env_lc="$(printf '%s' "${APP_ENV:-}" | tr '[:upper:]' '[:lower:]')"

# -----------------------------------------------------------------------------
# Error trap: drop + recreate the app database, stop postgres, wait for reload
# -----------------------------------------------------------------------------
stop_postgres_bounded() {
  set +e
  log_warn "Stopping postgres"

  local pid=""
  pid="$(cat /tmp/pg.pid 2>/dev/null || true)"

  if [[ -n "${PGDATA:-}" && -d "${PGDATA}" ]]; then
    PGPASSWORD="${SUPERUSER_PWD}" pg_ctl -D "${PGDATA}" -m fast stop >/dev/null 2>&1 || true
  fi

  if [[ -n "${pid}" ]]; then
    for _ in {1..20}; do
      kill -0 "${pid}" >/dev/null 2>&1 || { log_ok "Postgres process exited"; return 0; }
      sleep 0.25
    done
    kill "${pid}" >/dev/null 2>&1 || true
  fi

  return 0
}

trap_run() {
  local code=$?
  log_err "Critical failure (code=${code})"

  set +e

  if [[ "${app_env_lc}" == "test" ]]; then
  # CONFIRM_IRREVOCABLE_DATABASE_WIPE guard:
  # Database destruction requires an explicit, intentional opt-in.
  # APP_ENV alone no longer triggers any destructive action.
  if [ "${CONFIRM_IRREVOCABLE_DATABASE_WIPE:-false}" = "true" ]; then
    log_warn "CONFIRM_IRREVOCABLE_DATABASE_WIPE=true — database will be permanently destroyed and recreated"
    log_warn "Resetting database '${APP_DB_NAME}'..."

    # Provide app_db_name via --set and connect to a maintenance DB (postgres),
    # because you can't drop the DB you're connected to.
    PGPASSWORD="${SUPERUSER_PWD}" psql \
      -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
      -d postgres -v ON_ERROR_STOP=1 \
      --set=app_db_name="${APP_DB_NAME}" --set=test_db_name="${TEST_DB_NAME:-test_db}" \
      --set=mae_db_name="${MAE_DB_NAME:-mae}" \
      >/dev/null 2>&1 <<'SQL'
REVOKE CONNECT ON DATABASE :"app_db_name" FROM PUBLIC;
REVOKE CONNECT ON DATABASE :"test_db_name" FROM PUBLIC;
REVOKE CONNECT ON DATABASE :"mae_db_name" FROM PUBLIC;

SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'app_db_name'
  AND pid <> pg_backend_pid();

SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'test_db_name'
  AND pid <> pg_backend_pid();

SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = :'mae_db_name'
  AND pid <> pg_backend_pid();

DROP DATABASE IF EXISTS :"app_db_name" CASCADE;
DROP DATABASE IF EXISTS :"test_db_name" CASCADE;
DROP DATABASE IF EXISTS :"mae_db_name" CASCADE;
CREATE DATABASE :"app_db_name";
CREATE DATABASE :"test_db_name";
CREATE DATABASE :"mae_db_name";
SQL
  else
    log_ok "Database wipe skipped. Set CONFIRM_IRREVOCABLE_DATABASE_WIPE=true to enable destructive reset."
  fi
  fi

  stop_postgres_bounded

  if [[ "${app_env_lc}" == "test" ]]; then
    log_warn "Critical failure — waiting for container reload (test mode)"
    while true; do sleep 1; done
  else
    log_err "Critical failure — exiting so container runtime can restart the pod"
    exit 1
  fi
}

# ERR trap requires errtrace to propagate through functions/subshells.
set -E
trap trap_run ERR

# -----------------------------------------------------------------------------
# Graceful shutdown on SIGINT/SIGTERM
#
# docker-compose down / Ctrl+C should stop postgres and exit cleanly instead of
# leaving the container stuck in a wait-loop. We install explicit INT/TERM
# handlers that bypass the destructive error trap and just stop postgres.
# -----------------------------------------------------------------------------
handle_signal() {
  log_warn "Received termination signal \\u2014 stopping postgres and exiting cleanly"
  # Avoid invoking trap_run() from this path; we just want a bounded shutdown.
  trap - ERR
  stop_postgres_bounded
  exit 0
}

trap handle_signal INT TERM

# -----------------------------------------------------------------------------
# Step 1: Start postgres + run migrations
# -----------------------------------------------------------------------------
/workspace/scripts/run.sh

# -----------------------------------------------------------------------------
# Step 2 (test mode only): Run pgTAP tests as a separate lifecycle step.
# Issue #14 — test execution is decoupled from postgres startup/restart.
# run.sh starts postgres and applies migrations; run_tests.sh is responsible
# solely for test execution and can be invoked independently.
# -----------------------------------------------------------------------------
if [[ "${app_env_lc}" == "test" ]]; then
  /workspace/scripts/run_tests.sh
  # In test mode the container's job is done; exit cleanly.
  exit 0
fi

# -----------------------------------------------------------------------------
# Step 3 (operational mode only): Wait on postgres and stream logs on failure.
# Issue #17 — this block is the final step of entry_point.sh.
# -----------------------------------------------------------------------------
pg_pid="$(cat /tmp/pg.pid 2>/dev/null || true)"
log_ok "APP_ENV=${APP_ENV}; postgres running (operational mode)"

# Do not let operational monitor failures trigger trap_run() destructive path.
trap - ERR

if [[ -n "${pg_pid}" ]] && [[ "${pg_pid}" =~ ^[0-9]+$ ]]; then
# Monitor liveness without requiring child ownership.
while kill -0 "${pg_pid}" >/dev/null 2>&1; do
sleep 1
done
else
log_warn "No valid /tmp/pg.pid found; falling back to pg_isready monitor"
while pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" >/dev/null 2>&1; do
sleep 1
done
fi

log_err "Postgres exited unexpectedly (operational mode)"
exit 1
