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

# stdout is a terminal
is_tty() {
  [[ "${TTY_OVERRIDE:-}" == "1" ]] || [[ -t 1 ]]
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
  is_tty || return 0
  echo -e "${c_green}✅  $*${c_reset}"
}

log_warn() {
  is_tty || return 0
  is_debug || return 0
  echo -e "${c_yellow}⚠️  $*${c_reset}"
}

log_err() {
  # stderr TTY check is more correct for errors
  [[ -t 2 ]] || return 0
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

# docker is only required when we will actually use it (host/dev or docker-exec mode).
# In container-local mode (CONTAINER=-1), postgres is started separately and psql is local.
if [[ "${CONTAINER:-}" != "-1" ]]; then
  if ! [ -x "$(command -v docker)" ]; then
    log_err "docker is not installed"
    exit 1
  fi
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
  ADMIN_MIGRATIONS_PATH
  APP_MIGRATIONS_PATH

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

  SUPER_DATABASE_URL
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
# Docker bootstrap
# -----------------------------------------------------------------------------

if [[ "${CONTAINER:-}" == "-1" ]]; then
  log_warn "CONTAINER=-1; assuming Postgres is already running locally on ${DB_HOST}:${DB_PORT}"
elif [[ -z "${CONTAINER:-}" ]]; then
  log_info "Starting Postgres container on port ${DB_PORT}"

  RUNNING_POSTGRES_CONTAINER=$(docker ps --filter 'name=postgres' --filter "publish=${DB_PORT}" --format '{{.ID}}')
  if [[ -n "${RUNNING_POSTGRES_CONTAINER}" ]]; then
    log_err "A postgres container is already running on port ${DB_PORT}"
    echo >&2 "Kill it with:"
    echo >&2 "  docker kill ${RUNNING_POSTGRES_CONTAINER}"
    exit 1
  fi

  CONTAINER="mae_service_pg_$(uuidgen)"

  docker run \
    --env POSTGRES_USER="${SUPERUSER}" \
    --env POSTGRES_PASSWORD="${SUPERUSER_PWD}" \
    --health-cmd="pg_isready -U ${SUPERUSER} || exit 1" \
    --health-interval=1s \
    --health-timeout=5s \
    --health-retries=10 \
    --publish "${DB_PORT}":5432 \
    --detach \
    --name "${CONTAINER}" \
    postgres -N 1000 >/dev/null

  until [[ "$(docker inspect -f "{{.State.Health.Status}}" "${CONTAINER}")" == "healthy" ]]; do
    log_warn "Postgres is still unavailable - sleeping"
    sleep 1
  done

  log_ok "Postgres container is healthy"
else
  log_warn "CONTAINER set; assuming Postgres is reachable on ${DB_HOST}:${DB_PORT}"
fi

# -----------------------------------------------------------------------------
# Quiet Postgres helpers (stdout suppressed; errors still shown)
# -----------------------------------------------------------------------------
psql_super_db() {
  local db="$1"
  local sql="$2"

  # Container-local mode or host-local mode: use direct psql
  if [[ -z "${CONTAINER:-}" || "${CONTAINER:-}" == "-1" ]]; then
    PGPASSWORD="${SUPERUSER_PWD}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${SUPERUSER}" \
      -d "${db}" -v ON_ERROR_STOP=1 -q -c "${sql}" \
      1>/dev/null
    return
  fi

  # Docker-exec mode: use docker exec into the postgres container
  docker exec -i "${CONTAINER}" \
    psql -U "${SUPERUSER}" -d "${db}" -v ON_ERROR_STOP=1 -q -c "${sql}" \
    1>/dev/null
}

# -----------------------------------------------------------------------------
# 1) Ensure DB exists (as SUPERUSER)
# -----------------------------------------------------------------------------
log_info "Ensuring database exists via sqlx (superuser)"
sqlx database create --database-url "${SUPER_DATABASE_URL}"
log_ok "Database ensured"

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
log_info "Running admin migrations (superuser) from ./${ADMIN_MIGRATIONS_PATH}/"
if [[ "${DEBUG:-}" == "1" ]]; then
  sqlx migrate run --no-dotenv --database-url "${SUPER_DATABASE_URL}" --source "${ADMIN_MIGRATIONS_PATH}"
else
  sqlx migrate run --no-dotenv --database-url "${SUPER_DATABASE_URL}" --source "${ADMIN_MIGRATIONS_PATH}" >/dev/null
fi
log_ok "Admin migrations applied"

# -----------------------------------------------------------------------------
# 5) Grant runtime memberships
# -----------------------------------------------------------------------------
# These roles are expected to be created by admin_migrations:
#   - app_user
#   - table_creator
#   - migrator_user
log_info "Granting role memberships"
psql_super_db "${APP_DB_NAME}" "GRANT app_user TO ${APP_USER};"
psql_super_db "${APP_DB_NAME}" "GRANT table_creator TO ${TABLE_PROVISIONER_USER};"
psql_super_db "${APP_DB_NAME}" "GRANT app_migrator TO ${MIGRATOR_USER};"
# NOTE: we also want the migrator + table_creator to have the same priviledges as the app_user (IE - USAGE)
psql_super_db "${APP_DB_NAME}" "GRANT app_user TO ${MIGRATOR_USER};"
psql_super_db "${APP_DB_NAME}" "GRANT app_user TO ${TABLE_PROVISIONER_USER};"
log_ok "Memberships granted"

# -----------------------------------------------------------------------------
# 6) Set scopes / search_path to roles
# -----------------------------------------------------------------------------
log_info "Setting search_path / scope to roles"
psql_super_db "${APP_DB_NAME}" "
  -- Set search_path
  ALTER ROLE ${MIGRATOR_USER} SET search_path = app;
  ALTER ROLE ${TABLE_PROVISIONER_USER} SET search_path = app;
  ALTER ROLE ${APP_USER} SET search_path = app;
"
log_ok "Search_path's set"

log_ok "Premigration Complete"
log_ok "Good-bye"

exit 0
