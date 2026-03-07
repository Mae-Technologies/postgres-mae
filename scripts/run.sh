#!/usr/bin/env bash
# run.sh
#
# Container entrypoint (called by entry_point.sh):
#  - starts postgres in this container
#  - loads /workspace/.env via ENV_PATH
#  - runs sqlx_premigration.sh (multi-DB aware)
#  - runs pgTAP tests for every database and every principal
#  - keeps postgres running in non-test mode

set -euo pipefail

is_debug() { [[ "${DEBUG:-}" == "1" ]]; }

c_reset="\033[0m"; c_blue="\033[34m"; c_green="\033[32m"; c_yellow="\033[33m"; c_red="\033[31m"
log()      { echo -e "${c_blue}$*${c_reset}"; }
log_info() { is_debug || return 0; echo -e "${c_blue}🔎${c_reset} $*"; }
log_ok()   { echo -e "${c_green}📟${c_reset} $*"; }
log_warn() { echo -e "${c_yellow}😶${c_reset} $*"; }
log_err()  { echo -e "${c_red}🔥${c_reset} $*" >&2; }

cd /workspace

log_info "Container entrypoint starting"

export ENV_PATH="${ENV_PATH:-/workspace/.env}"
if [[ ! -f "${ENV_PATH}" ]]; then
  log_err "ENV_PATH not found: ${ENV_PATH}"
  exit 1
fi

require_var() {
  local name="$1"
  if [[ -z "${!name+x}" || -z "${!name}" ]]; then
    log_err "Required env var not set or empty: ${name}"
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
  PG_MAE_DATABASES
  API_MIGRATOR_PWD API_APP_USER_PWD API_PROVISIONER_PWD
  ACCOUNTING_MIGRATOR_PWD ACCOUNTING_APP_USER_PWD ACCOUNTING_PROVISIONER_PWD
  WIDGET_MIGRATOR_PWD WIDGET_APP_USER_PWD WIDGET_PROVISIONER_PWD
  QUEUE_MIGRATOR_PWD QUEUE_APP_USER_PWD QUEUE_PROVISIONER_PWD
)

for v in "${_env_vars[@]}"; do _preserve_var "${v}"; done

log_info "Loading env from ${ENV_PATH}"
set -a; source "${ENV_PATH}"; set +a

for v in "${_env_vars[@]}"; do _restore_var "${v}"; done

for v in APP_ENV DB_HOST DB_PORT SUPERUSER SUPERUSER_PWD; do require_var "${v}"; done

log_ok "Loaded env (runtime overrides preserved)"

app_env_lc="$(printf '%s' "${APP_ENV}" | tr '[:upper:]' '[:lower:]')"
case "${app_env_lc}" in
  test|dev|stage|prod) ;;
  *) log_err "Invalid APP_ENV='${APP_ENV}'"; exit 1 ;;
esac
log_ok "Running in APP_ENV=${APP_ENV}"

is_test_env=0
[[ "${app_env_lc}" == "test" ]] && is_test_env=1

should_exit=0

export POSTGRES_USER="${SUPERUSER}"
export POSTGRES_PASSWORD="${SUPERUSER_PWD}"
export DATABASE_URL="postgres://${SUPERUSER}:${SUPERUSER_PWD}@${DB_HOST}:${DB_PORT}/${APP_DB_NAME:-postgres}"

pg_log_file="/tmp/postgres.log"

log_info "Starting postgres on ${DB_HOST}:${DB_PORT} (APP_ENV=${APP_ENV})"

# Port is always 5432 (default). DB_PORT kept for flexibility/override.
if [[ "${app_env_lc}" != "test" ]]; then
  docker-entrypoint.sh postgres -p "${DB_PORT}" -N 1000 &
elif [[ -n "${PG_LOG:-}" ]]; then
  docker-entrypoint.sh postgres -p "${DB_PORT}" -N 1000 &
else
  docker-entrypoint.sh postgres -p "${DB_PORT}" -N 1000 >"${pg_log_file}" 2>&1 &
fi
pg_pid="$!"

failed=0
pg_started=1

stop_postgres_bounded() {
  set +e
  log_info "Stopping postgres"
  if [[ -n "${PGDATA:-}" && -d "${PGDATA}" ]]; then
    PGPASSWORD="${SUPERUSER_PWD}" pg_ctl -D "${PGDATA}" -m fast stop >/dev/null 2>&1 || true
  fi
  for _ in {1..20}; do
    kill -0 "${pg_pid}" >/dev/null 2>&1 || { log_ok "Postgres process exited"; return 0; }
    sleep 0.25
  done
  log_warn "Postgres PID still alive; sending SIGTERM"
  kill "${pg_pid}" >/dev/null 2>&1 || true
  return 0
}

cleanup() {
  set +e
  if [[ -z "${pg_started:-}" || -z "${pg_pid:-}" ]]; then return 0; fi
  if [[ "${is_test_env}" == "1" ]]; then log "Goodbye"; return 0; fi
  if [[ "${app_env_lc}" != "test" ]]; then
    if kill -0 "${pg_pid}" >/dev/null 2>&1; then
      log_warn "APP_ENV=${APP_ENV}; shutdown requested; stopping postgres"
      stop_postgres_bounded
    else
      [[ "${failed}" == "1" ]] && log_err "APP_ENV=${APP_ENV}; postgres already exited"
    fi
    log "Goodbye"
    return 0
  fi
}
trap cleanup EXIT

deadline=$((SECONDS + 30))
until pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" >/dev/null 2>&1; do
  if ((SECONDS >= deadline)); then
    log_err "Postgres did not become ready"
    if [[ -z "${PG_LOG:-}" && -f "${pg_log_file}" ]]; then
      echo >&2 "---- postgres.log (tail) ----"
      tail -n 200 "${pg_log_file}" >&2 || true
      echo >&2 "-----------------------------"
    fi
    failed=1; exit 1
  fi
  sleep 0.25
done
log_ok "Postgres is ready"

log_info "Running premigration script"
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
  failed=1; exit $rc
fi
log_ok "Premigration script finished"

# ─────────────────────────────────────────────────────────────────────────────
# pgTAP: run for every database, every principal
# ─────────────────────────────────────────────────────────────────────────────

# Resolve database list (mirrors premigration logic)
_multi_db_mode=0
if [[ -n "${PG_MAE_DATABASES:-}" ]]; then
  _multi_db_mode=1
  IFS=',' read -ra _pgtap_databases <<< "${PG_MAE_DATABASES}"
else
  _pgtap_databases=("${APP_DB_NAME:-postgres}")
fi

get_service_var() {
  local varname="${1}_${2}"
  echo "${!varname:-}"
}

run_pgtap_as() {
  local label="$1" user="$2" pwd="$3" db="$4" dir="$5"
  log_info "Running pgTAP as ${label} on ${db}"
  local conn="postgres://${user}:${pwd}@${DB_HOST}:${DB_PORT}/${db}"
  if [[ "${PG_TEST_LOG:-}" == "1" ]]; then
    pg_prove -v -d "${conn}" --ext .sql "${dir}"
  else
    pg_prove -v -d "${conn}" --ext .sql "${dir}" >/dev/null
  fi
}

tests_failed=0
tests_failed_rc=0
tests_failed_role=""
tests_failed_db=""

set +e

for _raw_db in "${_pgtap_databases[@]}"; do
  _db="$(echo "${_raw_db}" | xargs)"
  _service="${_db%_db}"
  _SERVICE="$(echo "${_service}" | tr '[:lower:]' '[:upper:]')"

  log_ok "── pgTAP: ${_db} ──"

  # Add pgtap extension to this database
  PGPASSWORD="${SUPERUSER_PWD}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
    -d "${_db}" -v ON_ERROR_STOP=1 -q -c "
DROP EXTENSION IF EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA test;
"

  # Resolve per-service credentials
  if [[ "${_multi_db_mode}" == "1" ]]; then
    _mig_user="${_service}_migrator"
    _mig_pwd="$(get_service_var "${_SERVICE}" "MIGRATOR_PWD")"
    _app_user="${_service}_app"
    _app_pwd="$(get_service_var "${_SERVICE}" "APP_USER_PWD")"
    _prov_user="${_service}_provisioner"
    _prov_pwd="$(get_service_var "${_SERVICE}" "PROVISIONER_PWD")"
  else
    _mig_user="${MIGRATOR_USER:-db_migrator}"
    _mig_pwd="${MIGRATOR_PWD:-}"
    _app_user="${APP_USER:-app}"
    _app_pwd="${APP_USER_PWD:-}"
    _prov_user="${TABLE_PROVISIONER_USER:-table_provisioner}"
    _prov_pwd="${TABLE_PROVISIONER_PWD:-}"
  fi

  # Run tests as each principal (stop on first failure within DB)
  for role_label in "SUPERUSER" "MIGRATOR" "TABLE_PROVISIONER" "APP_USER"; do
    case "${role_label}" in
      SUPERUSER)
        run_pgtap_as "admin@${_db}" "${SUPERUSER}" "${SUPERUSER_PWD}" "${_db}" "/workspace/tests"
        rc=$?
        ;;
      MIGRATOR)
        run_pgtap_as "${_service}_migrator@${_db}" "${_mig_user}" "${_mig_pwd}" "${_db}" "/workspace/tests/app_migrator_table_creator"
        rc=$?
        ;;
      TABLE_PROVISIONER)
        run_pgtap_as "${_service}_provisioner@${_db}" "${_prov_user}" "${_prov_pwd}" "${_db}" "/workspace/tests/app_migrator_table_creator"
        rc=$?
        ;;
      APP_USER)
        run_pgtap_as "${_service}_app@${_db}" "${_app_user}" "${_app_pwd}" "${_db}" "/workspace/tests/app_user"
        rc=$?
        ;;
      *) rc=1 ;;
    esac

    if [[ $rc -ne 0 ]]; then
      tests_failed=1
      tests_failed_rc=$rc
      tests_failed_role="${role_label}"
      tests_failed_db="${_db}"
      break 2
    fi
  done
done

set -e

if [[ "${tests_failed}" == "1" ]]; then
  log "___________________________"
  log ""
  log_warn "PGTAP TESTS FAILED as ${tests_failed_role} on ${tests_failed_db} (exit ${tests_failed_rc})"
  log ""
  log "___________________________"

  if [[ -z "${PG_LOG:-}" && -f "${pg_log_file}" && "${app_env_lc}" != "test" ]]; then
    echo >&2 "---- postgres.log (tail) ----"
    tail -n 200 "${pg_log_file}" >&2 || true
    echo >&2 "-----------------------------"
  fi

  if [[ "${app_env_lc}" == "test" ]]; then
    log_warn "waiting for container reload..."
    while true; do sleep 1; done
  fi

  failed=1; exit "${tests_failed_rc}"
fi

log "___________________________"
log ""
log_ok "pgTAP tests passed (all principals, all databases)"
log "___________________________"

log_ok "APP_ENV=${APP_ENV}; postgres running (operational mode)"
set +e
wait "${pg_pid}"
rc=$?
set -e
failed=1
log_err "Postgres exited unexpectedly (exit ${rc})"
exit "${rc}"
