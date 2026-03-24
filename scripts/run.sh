#!/usr/bin/env bash
# scripts/run.sh
#
# Container startup script:
# - loads /workspace/.env via ENV_PATH
# - starts postgres in the background (without exporting POSTGRES_USER/POSTGRES_PASSWORD
#   into the main process environment — Issue #15)
# - writes the postgres background PID to /tmp/pg.pid for entry_point.sh to use
# - waits for postgres to become ready
# - runs the premigration script
#
# pgTAP tests are handled separately by scripts/run_tests.sh (Issue #16).
# The final wait/stream-logs block lives in entry_point.sh (Issue #17).

set -euo pipefail

# -----------------------------------------------------------------------------
# Debug / TTY helpers
# -----------------------------------------------------------------------------
is_debug() { [[ "${DEBUG:-}" == "1" ]]; }

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
c_reset="\033[0m"
c_blue="\033[34m"
c_green="\033[32m"
c_yellow="\033[33m"
c_red="\033[31m"

log() {
  echo -e "${c_blue}$*${c_reset}"
}

log_info() {
  is_debug || return 0
  echo -e "${c_blue}🔎${c_reset} $*"
}

log_ok() {
  echo -e "${c_green}📟${c_reset} $*"
}

log_warn() {
  echo -e "${c_yellow}😶${c_reset} $*"
}

log_err() {
  echo -e "${c_red}🔥${c_reset} $*" >&2
}

cd /workspace

log_info "Container entrypoint starting"

# -----------------------------------------------------------------------------
# Load env with runtime overrides taking precedence (fallback to .env)
# -----------------------------------------------------------------------------
export ENV_PATH="${ENV_PATH:-/workspace/.env}"
if [[ ! -f "${ENV_PATH}" ]]; then
  log_err "ENV_PATH not found: ${ENV_PATH}"
  exit 1
fi

require_var() {
  local name="$1"
  if [[ -z "${!name+x}" ]]; then
    log_err "Required env var not set: ${name}"
    exit 1
  fi
  if [[ -z "${!name}" ]]; then
    log_err "Required env var is empty: ${name}"
    exit 1
  fi
}

_preserve_var() {
  local name="$1"
  if [[ "${!name+x}" == "x" ]]; then
    eval "__preserve__${name}=1"
    eval "__value__${name}=$(printf '%q' "${!name}")"
  else
    eval "__preserve__${name}=0"
  fi
}

_restore_var() {
  local name="$1"
  eval "local keep=\${__preserve__${name}:-0}"
  if [[ "${keep}" == "1" ]]; then
    eval "export ${name}=\${__value__${name}}"
  fi
}

_env_vars=(
  APP_ENV
  DB_HOST DB_PORT APP_DB_NAME
  SUPERUSER SUPERUSER_PWD
  MIGRATOR_USER MIGRATOR_PWD
  APP_USER APP_USER_PWD
  TABLE_PROVISIONER_USER TABLE_PROVISIONER_PWD
)

for v in "${_env_vars[@]}"; do
  _preserve_var "${v}"
done

log_info "Loading env from ${ENV_PATH}"
set -a
# shellcheck disable=SC1090
source "${ENV_PATH}"
set +a

for v in "${_env_vars[@]}"; do
  _restore_var "${v}"
done

for v in "${_env_vars[@]}"; do
  require_var "${v}"
done

log_ok "Loaded env (runtime overrides preserved)"

# -----------------------------------------------------------------------------
# Validate APP_ENV
# -----------------------------------------------------------------------------
app_env_lc="$(printf '%s' "${APP_ENV}" | tr '[:upper:]' '[:lower:]')"
case "${app_env_lc}" in
test | dev | stage | prod) ;;
*)
  log_err "Invalid APP_ENV='${APP_ENV}' (allowed: test, dev, stage, prod)"
  exit 1
  ;;
esac

log_ok "Running in APP_ENV=${APP_ENV}"

# -----------------------------------------------------------------------------
# Build DATABASE_URL (no POSTGRES_USER / POSTGRES_PASSWORD exported globally)
# Issue #15: POSTGRES_USER and POSTGRES_PASSWORD are passed only as inline env
# vars to docker-entrypoint.sh, not exported into the main process environment,
# so they are not visible in process lists or inherited by unrelated children.
# -----------------------------------------------------------------------------
DATABASE_URL="postgres://${SUPERUSER}:${SUPERUSER_PWD}@${DB_HOST}:${DB_PORT}/${APP_DB_NAME}"
export DATABASE_URL

# Postgres log file used when PG_LOG is unset (test / suppressed mode)
pg_log_file="/tmp/postgres.log"

log_info "Starting postgres on ${DB_HOST}:${DB_PORT} (APP_ENV=${APP_ENV})"

# Issue #15: pass POSTGRES_USER / POSTGRES_PASSWORD as inline env vars to the
# docker-entrypoint.sh child process only — they are never exported into this
# shell's environment and therefore do not appear in /proc/<pid>/environ or
# any other child's environment.
if [[ "${app_env_lc}" != "test" ]]; then
  POSTGRES_USER="${SUPERUSER}" POSTGRES_PASSWORD="${SUPERUSER_PWD}" \
    docker-entrypoint.sh postgres -p "${DB_PORT}" -N 1000 &
elif [[ -n "${PG_LOG:-}" ]]; then
  POSTGRES_USER="${SUPERUSER}" POSTGRES_PASSWORD="${SUPERUSER_PWD}" \
    docker-entrypoint.sh postgres -p "${DB_PORT}" -N 1000 &
else
  POSTGRES_USER="${SUPERUSER}" POSTGRES_PASSWORD="${SUPERUSER_PWD}" \
    docker-entrypoint.sh postgres -p "${DB_PORT}" -N 1000 >"${pg_log_file}" 2>&1 &
fi

pg_pid="$!"

# Write pg_pid to a file so entry_point.sh can wait on the postgres process
# after this script returns (Issue #17 — wait block lives in entry_point.sh).
echo "${pg_pid}" > /tmp/pg.pid

# -----------------------------------------------------------------------------
# Wait for postgres readiness
# -----------------------------------------------------------------------------
deadline=$((SECONDS + 30))
until pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" >/dev/null 2>&1; do
  if ((SECONDS >= deadline)); then
    log_err "Postgres did not become ready"
    if [[ -z "${PG_LOG:-}" && -f "${pg_log_file}" ]]; then
      echo >&2 "---- postgres.log (tail) ----"
      tail -n 200 "${pg_log_file}" >&2 || true
      echo >&2 "-----------------------------"
    fi
    exit 1
  fi
  sleep 0.25
done
log_ok "Postgres is ready"

# -----------------------------------------------------------------------------
# Run premigration script (stdout/stderr passthrough)
# -----------------------------------------------------------------------------
log_info "Running premigration script (local postgres mode)"

set +e
/workspace/scripts/sqlx_premigration.sh
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  log_err "Premigration script failed (exit ${rc})"
  if [[ -z "${PG_LOG:-}" && -f "${pg_log_file}" ]]; then
    echo >&2 "---- postgres.log (tail) ----"
    tail -n 200 "${pg_log_file}" >&2 || true
    echo >&2 "-----------------------------"
  fi
  exit $rc
fi

log_ok "Premigration script finished"

touch /tmp/postgres_init_done
