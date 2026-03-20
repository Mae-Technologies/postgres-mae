#!/usr/bin/env bash
# scripts/run_tests.sh
#
# Standalone pgTAP test runner.
# Loads env from ENV_PATH (or /workspace/.env), installs the pgTAP extension,
# and runs pg_prove for each principal in the correct order.
#
# Called by entry_point.sh after postgres is up and migrations have run.
# Exit code: 0 = all tests passed, non-zero = at least one suite failed.

set -euo pipefail

# -----------------------------------------------------------------------------
# Logging helpers (match run.sh style)
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
  [[ "${DEBUG:-}" == "1" ]] || return 0
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

# -----------------------------------------------------------------------------
# Env loading — honour runtime overrides already present in the environment
# -----------------------------------------------------------------------------
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
  DB_HOST DB_PORT APP_DB_NAME
  SUPERUSER SUPERUSER_PWD
  MIGRATOR_USER MIGRATOR_PWD
  APP_USER APP_USER_PWD
  TABLE_PROVISIONER_USER TABLE_PROVISIONER_PWD
)

for v in "${_env_vars[@]}"; do _preserve_var "${v}"; done

set -a
# shellcheck disable=SC1090
source "${ENV_PATH}"
set +a

for v in "${_env_vars[@]}"; do _restore_var "${v}"; done
for v in "${_env_vars[@]}"; do require_var "${v}"; done

log_ok "run_tests: env loaded"

# -----------------------------------------------------------------------------
# Install pgTAP extension (idempotent)
# -----------------------------------------------------------------------------
log_info "Adding pgTAP extension..."
PGPASSWORD="${SUPERUSER_PWD}" psql \
  -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
  -d "${APP_DB_NAME}" -v ON_ERROR_STOP=1 -q -c "
DROP EXTENSION IF EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA test;
CREATE EXTENSION IF NOT EXISTS btree_gist;
"
log_ok "pgTAP extension ready"

# -----------------------------------------------------------------------------
# Run pgTAP suites as each principal
# -----------------------------------------------------------------------------
run_pgtap_as() {
  local label="$1"
  local user="$2"
  local pwd="$3"
  local dir="$4"

  log_info "Running pgTAP as ${label} (${user})"

  if [[ "${PG_TEST_LOG:-}" == "1" ]]; then
    PGPASSWORD="${pwd}" pg_prove -v \
      -d "postgres://${user}:${pwd}@${DB_HOST}:${DB_PORT}/${APP_DB_NAME}" \
      --ext .sql \
      "${dir}"
  else
    PGPASSWORD="${pwd}" pg_prove -v \
      -d "postgres://${user}:${pwd}@${DB_HOST}:${DB_PORT}/${APP_DB_NAME}" \
      --ext .sql \
      "${dir}" >/dev/null
  fi
}

tests_failed=0
tests_failed_rc=0
tests_failed_role=""

set +e

# Order matters: migrator has broadest permissions, app is tightest.
for role_label in "SUPERUSER" "MIGRATOR_USER" "TABLE_PROVISIONER_USER" "APP_USER"; do
  case "${role_label}" in
  SUPERUSER)
    run_pgtap_as "admin" "${SUPERUSER}" "${SUPERUSER_PWD}" "/workspace/tests"
    rc=$?
    ;;
  MIGRATOR_USER)
    run_pgtap_as "app_migrator" "${MIGRATOR_USER}" "${MIGRATOR_PWD}" "/workspace/tests/app_migrator_table_creator"
    rc=$?
    ;;
  APP_USER)
    run_pgtap_as "app_user" "${APP_USER}" "${APP_USER_PWD}" "/workspace/tests/app_user"
    rc=$?
    ;;
  TABLE_PROVISIONER_USER)
    run_pgtap_as "table_creator" "${TABLE_PROVISIONER_USER}" "${TABLE_PROVISIONER_PWD}" "/workspace/tests/app_migrator_table_creator"
    rc=$?
    ;;
  *)
    rc=1
    ;;
  esac

  if [[ $rc -ne 0 ]]; then
    tests_failed=1
    tests_failed_rc=$rc
    tests_failed_role=$role_label
    break
  fi
done

set -e

if [[ "${tests_failed}" == "1" ]]; then
  log "___________________________"
  log ""
  log_warn "PGTAP TESTS FAILED as ${tests_failed_role} (exit ${tests_failed_rc})"
  log ""
  log "___________________________"
  exit "${tests_failed_rc}"
fi

log "___________________________"
log ""
log_ok "pgTAP tests passed (all principals)"
log "___________________________"

exit 0
