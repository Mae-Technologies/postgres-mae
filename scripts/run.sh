#!/usr/bin/env bash
# admin_migrations/sqlx_premigration_container.sh
#
# Container entrypoint:
# - starts postgres in THIS container
# - loads /workspace/.env via ENV_PATH
# - runs existing sqlx_premigration.sh with CONTAINER=-1
# - suppresses postgres stdout unless error or PG_LOG is set

set -euo pipefail

# -----------------------------------------------------------------------------
# Debug / TTY helpers (match premigration semantics)
# -----------------------------------------------------------------------------
is_debug() { [[ "${DEBUG:-}" == "1" ]]; }

# -----------------------------------------------------------------------------
# Logging helpers (emoji + two spaces, TTY-only)
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
#   - If a variable is already set in the environment, keep it.
#   - Otherwise, populate it from the .env file.
# -----------------------------------------------------------------------------
export ENV_PATH="${ENV_PATH:-/workspace/.env}"
if [[ ! -f "${ENV_PATH}" ]]; then
  log_err "ENV_PATH not found: ${ENV_PATH}"
  exit 1
fi

# Require variables (do NOT default)
require_var() {
  local name="$1"
  # ${!name+x} checks "is set", even if empty; then also reject empty explicitly
  if [[ -z "${!name+x}" ]]; then
    log_err "Required env var not set: ${name}"
    exit 1
  fi
  if [[ -z "${!name}" ]]; then
    log_err "Required env var is empty: ${name}"
    exit 1
  fi
}

# Preserve runtime overrides for ALL vars in your .env (keep if already set)
_preserve_var() {
  local name="$1"
  if [[ "${!name+x}" == "x" ]]; then
    # Mark as preserved + store value (can be empty; still considered "set")
    eval "__preserve__${name}=1"
    # printf %q to safely re-export later even with special chars
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

# List must match your .env variables (including optional/commented ones)
_env_vars=(
  APP_ENV

  DB_HOST
  DB_PORT
  APP_DB_NAME

  SUPERUSER
  SUPERUSER_PWD

  MIGRATOR_USER
  MIGRATOR_PWD

  APP_USER
  APP_USER_PWD

  TABLE_PROVISIONER_USER
  TABLE_PROVISIONER_PWD

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
# Require + validate APP_ENV (case-insensitive): test|dev|stage|prod
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
# Mode flags
# -----------------------------------------------------------------------------
is_test_env=0
if [[ "${app_env_lc}" == "test" ]]; then
  is_test_env=1
fi

# Set to 1 when we decide the container should exit (test flow).
# In non-test env, we aim to keep postgres running and never exit.
should_exit=0

# FIXME: I'm not a fan of exposting POSTGRES_USER and POSTGRES_PASSWORD -- if sqlx picks these up on a rouge script, it will blead into the public schema
DATABASE_URL=postgres://${SUPERUSER}:${SUPERUSER_PWD}@${DB_HOST}:${DB_PORT}/${APP_DB_NAME}
export POSTGRES_USER="${SUPERUSER}"
export POSTGRES_PASSWORD="${SUPERUSER_PWD}"
export DATABASE_URL

# Postgres logs:
# - if PG_LOG is set: inherit stdout/stderr (verbose)
# - else: redirect to a file; on failure, print tail for debugging
pg_log_file="/tmp/postgres.log"

log_info "Starting postgres on ${DB_HOST}:${DB_PORT} (APP_ENV=${APP_ENV})"

if [[ "${app_env_lc}" != "test" ]]; then
  # operational mode: show postgres logs on stdout/stderr
  docker-entrypoint.sh postgres -p "${DB_PORT}" -N 1000 &
elif [[ -n "${PG_LOG:-}" ]]; then
  docker-entrypoint.sh postgres -p "${DB_PORT}" -N 1000 &
else
  docker-entrypoint.sh postgres -p "${DB_PORT}" -N 1000 >"${pg_log_file}" 2>&1 &
fi

pg_pid="$!"

# -----------------------------------------------------------------------------
# Cleanup behavior:
# - test: always stop postgres on exit (success or failure)
# - non-test: keep postgres running; only stop it if the script is exiting due to failure
# -----------------------------------------------------------------------------
failed=0
pg_started=1

stop_postgres_bounded() {
  set +e
  log_info "Stopping postgres"

  # Ask postgres to stop
  if [[ -n "${PGDATA:-}" && -d "${PGDATA}" ]]; then
    PGPASSWORD="${SUPERUSER_PWD}" pg_ctl -D "${PGDATA}" -m fast stop >/dev/null 2>&1 || true
  fi

  # Bounded wait: avoid hanging forever if pg_pid isn't the server PID
  for _ in {1..20}; do
    kill -0 "${pg_pid}" >/dev/null 2>&1 || {
      log_ok "Postgres process exited"
      return 0
    }
    sleep 0.25
  done

  # kill in 20 seconds, 0.25 * 20 = 200
  log_warn "Postgres PID still alive; sending SIGTERM"
  kill "${pg_pid}" >/dev/null 2>&1 || true
  return 0
}

cleanup() {
  set +e

  # If postgres never started, nothing to do
  if [[ -z "${pg_started:-}" || -z "${pg_pid:-}" ]]; then
    return 0
  fi

  # TEST: always stop on exit
  if [[ "${is_test_env}" == "1" ]]; then
    log "Goodbye"
    return 0
  fi

  # NON-TEST: operational mode
  #
  # cleanup() only runs when the script is exiting (SIGTERM/Ctrl-C) or postgres died.
  # Distinguish:
  #   - If postgres is still running: we are shutting down intentionally -> stop it.
  #   - If postgres is not running: it already exited -> say goodbye (and rely on exit code).
  if [[ "${app_env_lc}" != "test" ]]; then
    if kill -0 "${pg_pid}" >/dev/null 2>&1; then
      log_warn "APP_ENV=${APP_ENV}; shutdown requested; stopping postgres"
      stop_postgres_bounded
      log "Goodbye"
    else
      # postgres already exited (crash or normal exit)
      if [[ "${failed}" == "1" ]]; then
        log_err "APP_ENV=${APP_ENV}; postgres already exited"
      else
        log_info "APP_ENV=${APP_ENV}; postgres already exited"
      fi
      log "Goodbye"
    fi
    return 0
  fi
}
trap cleanup EXIT

# Wait readiness; on failure dump logs if suppressed
deadline=$((SECONDS + 30))
until pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" >/dev/null 2>&1; do
  if ((SECONDS >= deadline)); then
    log_err "Postgres did not become ready"
    if [[ -z "${PG_LOG:-}" && -f "${pg_log_file}" ]]; then
      echo >&2 "---- postgres.log (tail) ----"
      tail -n 200 "${pg_log_file}" >&2 || true
      echo >&2 "-----------------------------"
    fi
    failed=1
    exit 1
  fi
  sleep 0.25
done
log_ok "Postgres is ready"

# -----------------------------------------------------------------------------
# Run premigration script (stdout/stderr passthrough)
# -----------------------------------------------------------------------------

# Run premigration script in local-postgres mode
log_info "Running premigration script (local postgres mode)"

set +e
/workspace/scripts/sqlx_premigration.sh
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
  log_err "Premigration script failed (exit ${rc})"

  # Only dump postgres logs when PG_LOG is not enabled
  if [[ -z "${PG_LOG:-}" && -f "${pg_log_file}" ]]; then
    echo >&2 "---- postgres.log (tail) ----"
    tail -n 200 "${pg_log_file}" >&2 || true
    echo >&2 "-----------------------------"
  fi
  failed=1
  exit $rc
fi

log_ok "Premigration script finished"

# TODO: move to it's own script
# -----------------------------------------------------------------------------
# pgTAP: run the suite as multiple principals (stop on first failure)
# -----------------------------------------------------------------------------
log_info "adding PGTap Extention..."
PGPASSWORD="${SUPERUSER_PWD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
  -d "${APP_DB_NAME}" -v ON_ERROR_STOP=1 -q -c "
-- cannot drop the extension for public -> superuser requires it to run tests
DROP EXTENSION IF EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA test;
"
log_ok "PGTap Extention added"

run_pgtap_as() {
  local label="$1"
  local user="$2"
  local pwd="$3"
  local dir="$4"

  log_info "Running pgTAP as ${label} (${user})"

  # Do NOT capture output in test mode; in non-test, optionally suppress unless PG_TEST_LOG=1
  if [[ "${PG_TEST_LOG:-}" == "1" ]]; then
    pg_prove -v \
      -d "postgres://${user}:${pwd}@${DB_HOST}:${DB_PORT}/${APP_DB_NAME}" \
      --ext .sql \
      $dir
  else
    pg_prove -v \
      -d "postgres://${user}:${pwd}@${DB_HOST}:${DB_PORT}/${APP_DB_NAME}" \
      --ext .sql \
      $dir >/dev/null
  fi
}

tests_failed=0
tests_failed_rc=0
tests_failed_role=""

set +e

# Order matters: migrator often has the broadest runtime-ish permissions, app is tightest,
# provisioner is capability-adjacent but inherits app_user DML in your model.
for role_label in "SUPERUSER" "ROLES" "MIGRATOR_USER" "TABLE_PROVISIONER_USER" "APP_USER"; do
  case "${role_label}" in
  SUPERUSER)
    run_pgtap_as "admin" "${SUPERUSER}" "${SUPERUSER_PWD}" "/workspace/tests"
    rc=$?
    ;;
  ROLES)
    run_pgtap_as "roles (superuser)" "${SUPERUSER}" "${SUPERUSER_PWD}" "/workspace/tests/roles"
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

  # Dump postgres logs only if they were suppressed
  if [[ -z "${PG_LOG:-}" && -f "${pg_log_file}" && "${app_env_lc}" != "test" ]]; then
    echo >&2 "---- postgres.log (tail) ----"
    tail -n 200 "${pg_log_file}" >&2 || true
    echo >&2 "-----------------------------"
  fi

  # Behavior:
  # - test: keep postgres running for inspection and wait for reload
  # - non-test: exit non-zero (cleanup decides whether to stop postgres)
  if [[ "${app_env_lc}" == "test" ]]; then
    log_warn "waiting for container reload..."
    while true; do
      sleep 1
    done
  fi

  failed=1
  exit "${tests_failed_rc}"
fi

log "___________________________"
log ""
log_ok "pgTAP tests passed (all principals)"
log "___________________________"

#TODO: This should be at the bottom of the entrypoint script -> the final destination
# -----------------------------------------------------------------------------
# Final behavior:
# - keep postgres running and stream logs
# -----------------------------------------------------------------------------
log_ok "APP_ENV=${APP_ENV}; postgres running (operational mode)"
set +e
wait "${pg_pid}"
rc=$?
set -e

failed=1
log_err "Postgres exited unexpectedly (exit ${rc})"
exit "${rc}"
