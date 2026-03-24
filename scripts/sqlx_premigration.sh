#!/usr/bin/bash
# sqlx_premigration.sh
#
# Production/dev/CI bootstrap with a strict separation:
#   - migrations/: executed as SUPERUSER against the mae schema.
#
# Key security goals:
#   - MIGRATOR_USER has minimal, typical production privileges
#   - All role creation and sensitive privilege/ownership operations occur only under SUPERUSER
#
# Migration strategy:
#   - Previously used sqlx-cli (compiled from source, ~10-15 min Docker build).
#   - Replaced with psql + ordered SQL files for fast, dependency-free migrations.
#   - Migration files use CREATE OR REPLACE / IF NOT EXISTS so re-runs are idempotent.
#   - A mae._migrations tracking table records applied files (replaces _sqlx_migrations).
#
# Output behavior:
#   - Postgres (psql) output suppressed unless error
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
  echo -e "${c_red}❌  $*${c_reset}" >&2
}

# -----------------------------------------------------------------------------
# Load env with runtime overrides taking precedence (fallback to .env)
# -----------------------------------------------------------------------------
export ENV_PATH="${ENV_PATH:-.env}"
if [[ ! -f "${ENV_PATH}" ]]; then
  log_err "ENV_PATH not found: ${ENV_PATH}"
  exit 1
fi

# Require variables (do NOT default)
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

# Preserve runtime overrides for ALL vars in your .env (keep if already set)
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
DATABASE_URL=postgres://${SUPERUSER}:${SUPERUSER_PWD}@${DB_HOST}:${DB_PORT}/${APP_DB_NAME}
export DATABASE_URL

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
log_info "Ensuring database exists"
PGPASSWORD="${SUPERUSER_PWD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
  -d postgres -v ON_ERROR_STOP=1 -q \
  -c "SELECT 1 FROM pg_database WHERE datname = '${APP_DB_NAME}'" \
  | grep -q 1 || \
PGPASSWORD="${SUPERUSER_PWD}" createdb -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" "${APP_DB_NAME}"

log_ok "Database ensured"

# Create schemas
psql_super_db "${APP_DB_NAME}" "
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'app_owner') THEN
    CREATE ROLE app_owner NOLOGIN;
END IF;
    CREATE SCHEMA IF NOT EXISTS app AUTHORIZATION app_owner;
    CREATE SCHEMA IF NOT EXISTS mae AUTHORIZATION app_owner;
    CREATE SCHEMA IF NOT EXISTS test AUTHORIZATION app_owner;
END
$$;
" >/dev/null 2>&1

# -----------------------------------------------------------------------------
# 2) Create migration tracking table (replaces _sqlx_migrations)
# -----------------------------------------------------------------------------
log_info "Ensuring migration tracking table"
psql_super_db "${APP_DB_NAME}" "
CREATE TABLE IF NOT EXISTS mae._migrations (
    id          SERIAL PRIMARY KEY,
    filename    TEXT NOT NULL UNIQUE,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
" >/dev/null 2>&1

# -----------------------------------------------------------------------------
# 3) Create LOGIN roles (as SUPERUSER)
# -----------------------------------------------------------------------------
log_info "Ensuring LOGIN roles exist (superuser)"
psql_super_db "${APP_DB_NAME}" "
DO $$
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
$$;
"
log_ok "LOGIN roles ensured"

# -----------------------------------------------------------------------------
# 4) Run migrations as SUPERUSER (ordered by filename, idempotent)
# -----------------------------------------------------------------------------
log_info "Running migrations from /workspace/migrations"
MIGRATION_DIR="/workspace/migrations"

for migration_file in $(ls "${MIGRATION_DIR}"/*.sql | sort); do
  filename="$(basename "${migration_file}")"

  # Check if already applied
  already_applied=$(PGPASSWORD="${SUPERUSER_PWD}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
    -d "${APP_DB_NAME}" -v ON_ERROR_STOP=1 -tAq \
    -c "SELECT COUNT(1) FROM mae._migrations WHERE filename = '${filename}'")

  if [[ "${already_applied}" == "1" ]]; then
    log_info "Skipping (already applied): ${filename}"
    continue
  fi

  log_info "Applying migration: ${filename}"
  PGPASSWORD="${SUPERUSER_PWD}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
    -d "${APP_DB_NAME}" \
    --set=search_path=mae,app,public \
    -v ON_ERROR_STOP=1 -q \
    -f "${migration_file}" 1>/dev/null

  # Record as applied
  psql_super_db "${APP_DB_NAME}" \
    "INSERT INTO mae._migrations (filename) VALUES ('${filename}') ON CONFLICT DO NOTHING;" \
    >/dev/null 2>&1

  log_ok "Applied: ${filename}"
done

log_ok "Migrations applied"

# -----------------------------------------------------------------------------
# 5) Grant runtime memberships
# -----------------------------------------------------------------------------
log_info "Granting role memberships"

psql_super_db "${APP_DB_NAME}" "
DO $$
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
$$;
"

psql_super_db "${APP_DB_NAME}" "
DO $$
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
$$;
"

psql_super_db "${APP_DB_NAME}" "
DO $$
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
$$;
"

psql_super_db "${APP_DB_NAME}" "
DO $$
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
$$;
"

psql_super_db "${APP_DB_NAME}" "
DO $$
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
$$;
"

log_ok "Memberships granted"

# Ensure db_migrator has a writable app schema and stable search_path for SQLx migrations
psql_super_db "${APP_DB_NAME}" "
DO $$
BEGIN
    -- Create app schema if it does not exist yet. Ownership stays with app_owner.
    IF NOT EXISTS (
        SELECT 1 FROM pg_namespace WHERE nspname = 'app'
    ) THEN
        CREATE SCHEMA app AUTHORIZATION app_owner;
    END IF;
    -- Only apply grants / search_path tweaks when db_migrator exists.
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'db_migrator') THEN
        GRANT USAGE, CREATE ON SCHEMA app TO db_migrator;
        EXECUTE 'ALTER ROLE db_migrator SET search_path = app, public';
    END IF;
END
$$;
"

# -----------------------------------------------------------------------------
# 6) Set scopes / search_path to roles
# -----------------------------------------------------------------------------
log_info "Setting search_path / scope to roles ${SEARCH_PATH}"
psql_super_db "${APP_DB_NAME}" "
ALTER ROLE ${SUPERUSER} SET search_path = test, ${SEARCH_PATH}, mae, public;
ALTER ROLE ${MIGRATOR_USER} SET search_path = test, ${SEARCH_PATH};
ALTER ROLE ${TABLE_PROVISIONER_USER} SET search_path = test, ${SEARCH_PATH};
ALTER ROLE ${APP_USER} SET search_path = test, ${SEARCH_PATH};
"
log_ok "Search_path's set"

log_ok "Premigration Complete"

exit 0
