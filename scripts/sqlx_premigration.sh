#!/usr/bin/bash
# sqlx_premigration.sh
#
# Multi-database bootstrap for postgres-mae.
#
# Supports two modes:
#
#   Single-DB (backward compat):
#     Set APP_DB_NAME + MIGRATOR_USER/PWD + APP_USER/PWD + TABLE_PROVISIONER_USER/PWD
#
#   Multi-DB (one DB per service):
#     Set PG_MAE_DATABASES="api_db,accounting_db,widget_db,queue_db"
#     Per-service creds are read from env vars:
#       {SERVICE_UPPER}_MIGRATOR_PWD
#       {SERVICE_UPPER}_APP_USER_PWD
#       {SERVICE_UPPER}_PROVISIONER_PWD
#     Where SERVICE is derived from the DB name by stripping a trailing _db suffix.
#     e.g. api_db -> API, accounting_db -> ACCOUNTING
#     Login role names: {service}_migrator, {service}_app, {service}_provisioner
#
# Security model:
#   - NOLOGIN roles (app_user, app_migrator, table_creator, app_owner) are cluster-wide.
#     Created by sqlx migrations (migrations/000100_roles.sql).
#   - LOGIN roles are per-service and cluster-scoped.
#   - Memberships are granted after migrations complete per-DB.

set -eo pipefail

is_debug() { [[ "${DEBUG:-}" == "1" ]]; }

c_reset="\033[0m"; c_blue="\033[34m"; c_green="\033[32m"; c_yellow="\033[33m"; c_red="\033[31m"
log_info() { is_debug || return 0; echo -e "${c_blue}🧩  $*${c_reset}"; }
log_ok()   { echo -e "${c_green} $*${c_reset}"; }
log_warn() { echo -e "${c_yellow}⚠️  $*${c_reset}"; }
log_err()  { echo -e "${c_red}❌  $*${c_reset}" >&2; }

if ! [ -x "$(command -v sqlx)" ]; then
  log_err "sqlx is not installed"
  exit 1
fi

export ENV_PATH="${ENV_PATH:-.env}"
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
  SEARCH_PATH PG_MAE_DATABASES
  API_MIGRATOR_PWD API_APP_USER_PWD API_PROVISIONER_PWD
  ACCOUNTING_MIGRATOR_PWD ACCOUNTING_APP_USER_PWD ACCOUNTING_PROVISIONER_PWD
  WIDGET_MIGRATOR_PWD WIDGET_APP_USER_PWD WIDGET_PROVISIONER_PWD
  QUEUE_MIGRATOR_PWD QUEUE_APP_USER_PWD QUEUE_PROVISIONER_PWD
)

for v in "${_env_vars[@]}"; do _preserve_var "${v}"; done

log_info "Loading env from ${ENV_PATH}"
set -a; source "${ENV_PATH}"; set +a

for v in "${_env_vars[@]}"; do _restore_var "${v}"; done

for v in DB_HOST DB_PORT SUPERUSER SUPERUSER_PWD SEARCH_PATH; do require_var "${v}"; done

log_ok "Loaded env (runtime overrides preserved)"

# Resolve database list
_multi_db_mode=0
if [[ -n "${PG_MAE_DATABASES:-}" ]]; then
  _multi_db_mode=1
  IFS=',' read -ra _databases <<< "${PG_MAE_DATABASES}"
  log_ok "Multi-DB mode: ${PG_MAE_DATABASES}"
else
  require_var APP_DB_NAME
  _databases=("${APP_DB_NAME}")
  log_ok "Single-DB mode: ${APP_DB_NAME}"
fi

psql_super_db() {
  local db="$1" sql="$2"
  PGPASSWORD="${SUPERUSER_PWD}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
    -d "${db}" -v ON_ERROR_STOP=1 -q -c "${sql}" \
    1>/dev/null
}

get_service_var() {
  local varname="${1}_${2}"
  echo "${!varname:-}"
}

for _raw_db in "${_databases[@]}"; do
  _db="$(echo "${_raw_db}" | xargs)"
  _service="${_db%_db}"
  _SERVICE="$(echo "${_service}" | tr '[:lower:]' '[:upper:]')"

  log_ok "── Setting up database: ${_db} (service: ${_service}) ──"

  if [[ "${_multi_db_mode}" == "1" ]]; then
    _mig_user="${_service}_migrator"
    _mig_pwd="$(get_service_var "${_SERVICE}" "MIGRATOR_PWD")"
    _app_user="${_service}_app"
    _app_pwd="$(get_service_var "${_SERVICE}" "APP_USER_PWD")"
    _prov_user="${_service}_provisioner"
    _prov_pwd="$(get_service_var "${_SERVICE}" "PROVISIONER_PWD")"

    [[ -z "${_mig_pwd}" ]]  && { log_err "Missing ${_SERVICE}_MIGRATOR_PWD for ${_db}";  exit 1; }
    [[ -z "${_app_pwd}" ]]  && { log_err "Missing ${_SERVICE}_APP_USER_PWD for ${_db}";  exit 1; }
    [[ -z "${_prov_pwd}" ]] && { log_err "Missing ${_SERVICE}_PROVISIONER_PWD for ${_db}"; exit 1; }
  else
    require_var MIGRATOR_USER; require_var MIGRATOR_PWD
    require_var APP_USER; require_var APP_USER_PWD
    require_var TABLE_PROVISIONER_USER; require_var TABLE_PROVISIONER_PWD
    _mig_user="${MIGRATOR_USER}";          _mig_pwd="${MIGRATOR_PWD}"
    _app_user="${APP_USER}";               _app_pwd="${APP_USER_PWD}"
    _prov_user="${TABLE_PROVISIONER_USER}"; _prov_pwd="${TABLE_PROVISIONER_PWD}"
  fi

  _db_url="postgres://${SUPERUSER}:${SUPERUSER_PWD}@${DB_HOST}:${DB_PORT}/${_db}"

  # 1) Create DB
  log_info "Creating database ${_db}"
  sqlx database create --database-url "${_db_url}"
  log_ok "Database ${_db} created/exists"

  # 2) Create schemas
  psql_super_db "${_db}" "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_owner') THEN
    CREATE ROLE app_owner NOLOGIN;
  END IF;
  CREATE SCHEMA IF NOT EXISTS app  AUTHORIZATION app_owner;
  CREATE SCHEMA IF NOT EXISTS mae  AUTHORIZATION app_owner;
  CREATE SCHEMA IF NOT EXISTS test AUTHORIZATION app_owner;
END
\$\$;
" 2>/dev/null

  # 3) Drop mae._sqlx_migrations to allow clean re-apply of mae-schema migrations
  psql_super_db "${_db}" "DROP TABLE IF EXISTS mae._sqlx_migrations;" 2>/dev/null

  # 4) Create per-service LOGIN roles (cluster-level, idempotent)
  log_info "Ensuring LOGIN roles for ${_service}"
  psql_super_db "${_db}" "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${_mig_user}') THEN
    CREATE ROLE ${_mig_user} LOGIN PASSWORD '${_mig_pwd}';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${_app_user}') THEN
    CREATE ROLE ${_app_user} LOGIN PASSWORD '${_app_pwd}';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${_prov_user}') THEN
    CREATE ROLE ${_prov_user} LOGIN PASSWORD '${_prov_pwd}';
  END IF;
END
\$\$;
"
  log_ok "LOGIN roles ensured for ${_service}"

  # 5) Run sqlx migrations
  log_info "Running migrations on ${_db}"
  if [[ "${DEBUG:-}" == "1" ]]; then
    sqlx migrate run --database-url "${_db_url}?options=-csearch_path%3Dmae"
  else
    sqlx migrate run --database-url "${_db_url}?options=-csearch_path%3Dmae" >/dev/null
  fi
  log_ok "Migrations applied to ${_db}"

  # 6) Grant NOLOGIN memberships
  log_info "Granting memberships for ${_service}"

  # migrator -> app_migrator + app_user
  psql_super_db "${_db}" "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_auth_members m
    JOIN pg_roles rr ON rr.oid = m.roleid JOIN pg_roles rm ON rm.oid = m.member
    WHERE rr.rolname = 'app_migrator' AND rm.rolname = '${_mig_user}') THEN
    EXECUTE format('GRANT %I TO %I', 'app_migrator', '${_mig_user}');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_auth_members m
    JOIN pg_roles rr ON rr.oid = m.roleid JOIN pg_roles rm ON rm.oid = m.member
    WHERE rr.rolname = 'app_user' AND rm.rolname = '${_mig_user}') THEN
    EXECUTE format('GRANT %I TO %I', 'app_user', '${_mig_user}');
  END IF;
END
\$\$;
"

  # provisioner -> table_creator + app_user
  psql_super_db "${_db}" "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_auth_members m
    JOIN pg_roles rr ON rr.oid = m.roleid JOIN pg_roles rm ON rm.oid = m.member
    WHERE rr.rolname = 'table_creator' AND rm.rolname = '${_prov_user}') THEN
    EXECUTE format('GRANT %I TO %I', 'table_creator', '${_prov_user}');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_auth_members m
    JOIN pg_roles rr ON rr.oid = m.roleid JOIN pg_roles rm ON rm.oid = m.member
    WHERE rr.rolname = 'app_user' AND rm.rolname = '${_prov_user}') THEN
    EXECUTE format('GRANT %I TO %I', 'app_user', '${_prov_user}');
  END IF;
END
\$\$;
"

  # app login -> app_user
  psql_super_db "${_db}" "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_auth_members m
    JOIN pg_roles rr ON rr.oid = m.roleid JOIN pg_roles rm ON rm.oid = m.member
    WHERE rr.rolname = 'app_user' AND rm.rolname = '${_app_user}') THEN
    EXECUTE format('GRANT %I TO %I', 'app_user', '${_app_user}');
  END IF;
END
\$\$;
"

  log_ok "Memberships granted for ${_service}"

  # 7) Set search_path per role
  log_info "Setting search_path for ${_service} roles"
  psql_super_db "${_db}" "
ALTER ROLE ${_mig_user}  SET search_path = test, ${SEARCH_PATH}, mae;
ALTER ROLE ${_prov_user} SET search_path = test, ${SEARCH_PATH};
ALTER ROLE ${_app_user}  SET search_path = test, ${SEARCH_PATH};
"
  log_ok "search_path set for ${_service}"
done

# Set superuser search_path cluster-wide
psql_super_db "${_databases[0]}" "
ALTER ROLE ${SUPERUSER} SET search_path = test, ${SEARCH_PATH}, mae, public;
"

log_ok "Premigration complete (${#_databases[@]} database(s))"
exit 0
