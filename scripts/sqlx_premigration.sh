#!/usr/bin/bash
# init_db.sh
#
# Starts local Postgres (Docker), creates LOGIN roles used by SQLx + the app,
# runs migrations, and then grants membership to NOLOGIN roles.
#
# Requirements implemented:
#!/usr/bin/bash
# init_db.sh
#
# Production/dev/CI bootstrap with a strict separation:
#   - admin_migrations/: executed as SUPERUSER (high-trust). Contains 01-05 (roles/functions/lockdowns).
#   - migrations/: executed as MIGRATOR_USER (low-trust). Contains normal app schema migrations.
#
# Key security goals:
#   - MIGRATOR_USER has minimal, typical production privileges
#   - All role creation and sensitive privilege/ownership operations occur only under SUPERUSER
#
# SQLx usage:
#   - Admin migrations:
#       sqlx migrate run --database-url <superuser-url> --source admin_migrations
#   - App migrations:
#       sqlx migrate run --database-url <migrator-url> --source migrations
#
# Output behavior:
#   - Postgres (psql) output suppressed unless error
#   - sqlx output NOT suppressed
#   - Colored, emoji-prefixed stage logs (emoji + two spaces)

set -eo pipefail

is_debug() {
  [[ "${DEBUG:-}" == "1" ]]
}

# -----------------------------------------------------------------------------
# Logging helpers (emoji + two spaces, TTY-only)
# -----------------------------------------------------------------------------
c_reset="\033[0m"
c_blue="\033[34m"
c_green="\033[32m"
c_yellow="\033[33m"
c_red="\033[31m"

log_info() {
  is_debug || return 0
  echo -e "${c_blue}🧩  $*${c_reset}"
}

log_ok() {
  echo -e "${c_green} $*${c_reset}"
}

log_warn() {
  echo -e "${c_yellow}⚠️  $*${c_reset}"
}

log_err() {
  # stderr TTY check is more correct for errors
  echo -e "${c_red}❌  $*${c_reset}" >&2
}

# -----------------------------------------------------------------------------
# Tooling checks
# -----------------------------------------------------------------------------
if ! [ -x "$(command -v sqlx)" ]; then
  log_err "sqlx is not installed"
  echo >&2 "Install:"
  echo >&2 "  cargo install --version='~0.8' sqlx-cli --no-default-features --features rustls,postgres"
  exit 1
fi

# -----------------------------------------------------------------------------
# Load env with runtime overrides taking precedence (fallback to .env)
#   - If a variable is already set in the environment, keep it.
#   - Otherwise, populate it from the .env file.
# -----------------------------------------------------------------------------
export ENV_PATH="${ENV_PATH:-.env}"
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

  SEARCH_PATH
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
# Quiet Postgres helpers (stdout suppressed; errors still shown)
# -----------------------------------------------------------------------------
psql_super_db() {
  local db="$1"
  local sql="$2"

  PGPASSWORD="${SUPERUSER_PWD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
    -d "${db}" -v ON_ERROR_STOP=1 -q -c "${sql}" \
    1>/dev/null

}

# -----------------------------------------------------------------------------
# 1) Ensure DB exists (as SUPERUSER)
# -----------------------------------------------------------------------------
log_info "Ensuring database exists via sqlx (superuser)"
sqlx database create --database-url "${DATABASE_URL}"

log_ok "Database ensured"

# Dropping sqlx table
#
# WARN: cannot drop any other migration tables as they're not ours! the public ones can be reapplied without error - and SHOULD be reapplied
psql_super_db "${APP_DB_NAME}" "
DROP TABLE IF EXISTS mae._sqlx_migrations;
"

# Create mae schema for sqlx migrations

psql_super_db "${APP_DB_NAME}" "

DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT
            1
        FROM
            pg_roles
        WHERE
            rolname = 'app_owner') THEN
    CREATE ROLE app_owner NOLOGIN;
END IF;
    -- Create schema owned by app_owner
    CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION app_owner;
    CREATE SCHEMA IF NOT EXISTS mae AUTHORIZATION app_owner;
    CREATE SCHEMA IF NOT EXISTS test AUTHORIZATION app_owner;
END
\$\$;
"

# setting role
#
# psql_super_db "${APP_DB_NAME}"

# -----------------------------------------------------------------------------
# 2) Create LOGIN roles (as SUPERUSER) - these are actual DB users
# -----------------------------------------------------------------------------
log_info "Ensuring LOGIN roles exist (superuser)"
psql_super_db "${APP_DB_NAME}" "
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${APP_USER}') THEN
    CREATE ROLE ${APP_USER} LOGIN PASSWORD '${APP_USER_PWD}';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${MIGRATOR_USER}') THEN
    CREATE ROLE ${MIGRATOR_USER} LOGIN PASSWORD '${MIGRATOR_PWD}';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${TABLE_PROVISIONER_USER}') THEN
    CREATE ROLE ${TABLE_PROVISIONER_USER} LOGIN PASSWORD '${TABLE_PROVISIONER_PWD}';
  END IF;
END
\$\$;
"
log_ok "LOGIN roles ensured"

# -----------------------------------------------------------------------------
# 4) Run admin migrations as SUPERUSER against admin_migrations/
# -----------------------------------------------------------------------------
# This is where 01-05 live now (roles/functions/lockdowns).
log_info "Running admin migrations"
if [[ "${DEBUG:-}" == "1" ]]; then
  sqlx migrate run --database-url "${DATABASE_URL}?options=-csearch_path%3Dmae"
else
  sqlx migrate run >/dev/null
fi
log_ok "Migrations applied"

# -----------------------------------------------------------------------------
# 5) Grant runtime memberships
# -----------------------------------------------------------------------------
# These roles are expected to be created by admin_migrations:
#   - app_user
#   - table_creator
#   - migrator_user
log_info "Granting role memberships"

# psql_super_db "${APP_DB_NAME}" "
# DO \$\$
# BEGIN
#   IF NOT EXISTS (
#     SELECT 1
#     FROM pg_auth_members m
#     JOIN pg_roles r_role   ON r_role.oid = m.roleid
#     JOIN pg_roles r_member ON r_member.oid = m.member
#     WHERE r_role.rolname = 'app_owner'
#       AND r_member.rolname = '${SUPERUSER}'
#   ) THEN
#     EXECUTE format('GRANT %I TO %I', 'app_owner', '${SUPERUSER}');
#   END IF;
# END
# \$\$;
# "

psql_super_db "${APP_DB_NAME}" "
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_auth_members m
    JOIN pg_roles r_role   ON r_role.oid = m.roleid
    JOIN pg_roles r_member ON r_member.oid = m.member
    WHERE r_role.rolname = 'app_user'
      AND r_member.rolname = '${APP_USER}'
  ) THEN
    EXECUTE format('GRANT %I TO %I', 'app_user', '${APP_USER}');
  END IF;
END
\$\$;
"

psql_super_db "${APP_DB_NAME}" "
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_auth_members m
    JOIN pg_roles r_role   ON r_role.oid = m.roleid
    JOIN pg_roles r_member ON r_member.oid = m.member
    WHERE r_role.rolname = 'table_creator'
      AND r_member.rolname = '${TABLE_PROVISIONER_USER}'
  ) THEN
    EXECUTE format('GRANT %I TO %I', 'table_creator', '${TABLE_PROVISIONER_USER}');
  END IF;
END
\$\$;
"

psql_super_db "${APP_DB_NAME}" "
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_auth_members m
    JOIN pg_roles r_role   ON r_role.oid = m.roleid
    JOIN pg_roles r_member ON r_member.oid = m.member
    WHERE r_role.rolname = 'app_migrator'
      AND r_member.rolname = '${MIGRATOR_USER}'
  ) THEN
    EXECUTE format('GRANT %I TO %I', 'app_migrator', '${MIGRATOR_USER}');
  END IF;
END
\$\$;
"

## Migrator inherits app_user privileges
psql_super_db "${APP_DB_NAME}" "
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_auth_members m
    JOIN pg_roles r_role   ON r_role.oid = m.roleid
    JOIN pg_roles r_member ON r_member.oid = m.member
    WHERE r_role.rolname = 'app_user'
      AND r_member.rolname = '${MIGRATOR_USER}'
  ) THEN
    EXECUTE format('GRANT %I TO %I', 'app_user', '${MIGRATOR_USER}');
  END IF;
END
\$\$;
"

## Table provisioner inherits app_user privileges
psql_super_db "${APP_DB_NAME}" "
DO \$\$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_auth_members m
    JOIN pg_roles r_role   ON r_role.oid = m.roleid
    JOIN pg_roles r_member ON r_member.oid = m.member
    WHERE r_role.rolname = 'app_user'
      AND r_member.rolname = '${TABLE_PROVISIONER_USER}'
  ) THEN
    EXECUTE format('GRANT %I TO %I', 'app_user', '${TABLE_PROVISIONER_USER}');
  END IF;
END
\$\$;
"

log_ok "Memberships granted"

# -----------------------------------------------------------------------------
# 6) Set scopes / search_path to roles
# -----------------------------------------------------------------------------
log_info "Setting search_path / scope to roles ${SEARCH_PATH}"
psql_super_db "${APP_DB_NAME}" "
  -- Set search_path
ALTER ROLE ${SUPERUSER} SET search_path = test, ${SEARCH_PATH}, mae, public;
  ALTER ROLE ${MIGRATOR_USER} SET search_path = test, ${SEARCH_PATH};
  ALTER ROLE ${TABLE_PROVISIONER_USER} SET search_path = test, ${SEARCH_PATH};
  ALTER ROLE ${APP_USER} SET search_path = test, ${SEARCH_PATH};
"
log_ok "Search_path's set"

log_ok "Premigration Complete"
log_ok "Good-bye"

exit 0
