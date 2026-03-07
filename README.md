# postgres-mae

A hardened, opinionated Postgres base image for Mae-Technologies services.

`postgres-mae` extends the official `postgres` image. At startup it:
1. Starts Postgres
2. Runs admin premigrations (creates databases, schemas, roles, ACLs)
3. Runs pgTAP tests against every database and every principal
4. Stays running as a normal Postgres server (in non-test envs)

Image is published to **GHCR**: `ghcr.io/mae-technologies/postgres-mae`

---

## One Database Per Service

Each Mae-Technologies backend service (`api`, `accounting`, `widget`, `queue`) gets
its **own isolated database**. No database is shared between services. This
provides:

- Hard data isolation — a bug in one service cannot corrupt another's data
- Independent schema evolution — each service migrates its own DB
- Per-service access control — credentials are scoped to one database

### Database names (canonical)

| Service    | Database        |
|------------|-----------------|
| api        | `api_db`        |
| accounting | `accounting_db` |
| widget     | `widget_db`     |
| queue      | `queue_db`      |

---

## Configuration

### Multi-DB mode (recommended)

Set `PG_MAE_DATABASES` to a comma-separated list of database names:

```
PG_MAE_DATABASES=api_db,accounting_db,widget_db,queue_db
```

For each database, the **service name** is derived by stripping a trailing `_db`
suffix (`api_db` → `api`). Per-service login roles are created automatically:

| Role pattern          | Inherits                      | Purpose                      |
|-----------------------|-------------------------------|------------------------------|
| `{service}_migrator`  | `app_migrator` + `app_user`   | Run SQLx migrations          |
| `{service}_app`       | `app_user`                    | Runtime application access   |
| `{service}_provisioner` | `table_creator` + `app_user` | Dynamic table provisioning  |

Passwords are supplied via env vars:

```
{SERVICE_UPPER}_MIGRATOR_PWD
{SERVICE_UPPER}_APP_USER_PWD
{SERVICE_UPPER}_PROVISIONER_PWD
```

Example for the `api_db`:

```
API_MIGRATOR_PWD=api_migrator_secret
API_APP_USER_PWD=api_app_secret
API_PROVISIONER_PWD=api_provisioner_secret
```

### Single-DB mode (backward compat)

Omit `PG_MAE_DATABASES` and set `APP_DB_NAME` with the original single-role vars:

```
APP_DB_NAME=mae_test
MIGRATOR_USER=db_migrator
MIGRATOR_PWD=migrator_secret
APP_USER=app
APP_USER_PWD=secret
TABLE_PROVISIONER_USER=table_provisioner
TABLE_PROVISIONER_PWD=provisioner_secret
```

---

## Connection Strings (local dev)

Port is always **5432** (default Postgres).

```
# api service
postgres://api_migrator:api_migrator_secret@localhost:5432/api_db
postgres://api_app:api_app_secret@localhost:5432/api_db
postgres://api_provisioner:api_provisioner_secret@localhost:5432/api_db

# accounting service
postgres://accounting_migrator:accounting_migrator_secret@localhost:5432/accounting_db
postgres://accounting_app:accounting_app_secret@localhost:5432/accounting_db

# widget service
postgres://widget_migrator:widget_migrator_secret@localhost:5432/widget_db
postgres://widget_app:widget_app_secret@localhost:5432/widget_db

# queue service
postgres://queue_migrator:queue_migrator_secret@localhost:5432/queue_db
postgres://queue_app:queue_app_secret@localhost:5432/queue_db
```

---

## Local Dev (Docker Compose)

```bash
docker compose up --build
```

This builds the image locally, initialises all 4 service databases, runs
pgTAP tests, and keeps Postgres running.

To rebuild on code changes:

```bash
docker compose watch
```

---

## Running pgTAP Tests

Tests are run automatically at startup in `APP_ENV=test`. To observe output:

```bash
# Show pgTAP output
PG_TEST_LOG=1 docker compose up --build

# Stream postgres logs too
PG_LOG=1 docker compose up --build
```

To run the build-and-test cycle manually:

```bash
docker build -t pg-mae-schema-test . && docker run --rm pg-mae-schema-test 2>&1 | tail -30
```

---

## Role Model (NOLOGIN roles, cluster-wide)

| Role             | Purpose                                     |
|------------------|---------------------------------------------|
| `app_owner`      | Owns schemas + functions                    |
| `app_migrator`   | Schema DDL (CREATE TABLE, indexes, etc.)    |
| `table_creator`  | Dynamic table provisioning                  |
| `app_user`       | Runtime DML (SELECT, INSERT, UPDATE, DELETE)|

Per-service LOGIN roles inherit from these NOLOGIN roles. NOLOGIN roles are
created by sqlx migrations (`migrations/000100_roles.sql`) and are shared
cluster-wide across all databases on the instance.

---

## References

- [pgTAP documentation](https://pgtap.org/documentation.html#has_column)
- [pgpedia](https://pgpedia.info/search.html)
