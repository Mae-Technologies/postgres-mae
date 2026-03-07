# postgres-mae

**postgres-mae** is a PostgreSQL initialization library for Mae-Technologies microservices. It bootstraps a Postgres instance with a hardened role model, schema functions, and a pgTAP test suite.

[![pgTAP Tests](https://github.com/Mae-Technologies/postgres-mae/actions/workflows/test.yml/badge.svg)](https://github.com/Mae-Technologies/postgres-mae/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](#license)

---

## What it does

postgres-mae provisions a fully configured PostgreSQL database suitable for Mae-Technologies microservices:

- **Schemas** — sets up the `app` (application objects) and `mae` (internal system objects) schemas
- **Role model** — creates four NOLOGIN permission roles that map cleanly to service principals
- **SQL functions** — installs a suite of safe DDL and ACL helpers (`create_table_from_spec`, `apply_table_acl`, and more)
- **DDL guard** — an event trigger blocks raw `CREATE TABLE`; all tables must be created via `create_table_from_spec`
- **DELETE guard** — a row-level trigger blocks direct `DELETE`; records must be retired by setting `status = 'deleted'` or `status = 'archived'`
- **pgTAP test suite** — validates correctness across all four role principals on every build

---

## Role model

postgres-mae defines four NOLOGIN roles. Application login users are created separately and granted membership in the appropriate role.

| Role | Purpose | Permitted operations |
|---|---|---|
| `app_owner` | Schema owner | Full DDL on the `app` schema |
| `app_migrator` | sqlx migration runner | `create_table_from_spec`, `CREATE INDEX`, `CREATE SEQUENCE` |
| `table_creator` | Runtime table provisioning | `create_table_from_spec` only |
| `app_user` | Application CRUD | `SELECT`, `INSERT`, `UPDATE` (no `DELETE`, no DDL) |

Login roles are created by `scripts/sqlx_premigration.sh` and inherit from these permission roles:

| Login role | Inherits from | Configured by |
|---|---|---|
| `db_migrator` (`MIGRATOR_USER`) | `app_migrator` | premigration script |
| `app` (`APP_USER`) | `app_user` | premigration script |
| `table_provisioner` (`TABLE_PROVISIONER_USER`) | `table_creator` | premigration script (optional) |

---

## Quick start

Pull and run the pre-built image with docker-compose:

```yaml
services:
  postgres:
    image: ghcr.io/mae-technologies/postgres-mae:latest
    environment:
      APP_DB_NAME: my_db
      APP_USER: app
      APP_USER_PWD: secret
      MIGRATOR_USER: db_migrator
      MIGRATOR_PWD: migrator_secret
      SUPERUSER: postgres
      SUPERUSER_PWD: password
    ports:
      - "5432:5432"
```

The container runs the full migration stack on startup. Once healthy, connect using the login role appropriate for your service tier.

---

## Environment variables

All variables are read from the environment (or from `.env` when running scripts locally).

| Variable | Default | Description |
|---|---|---|
| `APP_ENV` | `test` | Runtime environment. Accepted: `prod`, `dev`, `stage`, `test` (case-insensitive). |
| `DB_HOST` | `127.0.0.1` | PostgreSQL host. |
| `DB_PORT` | `5432` | PostgreSQL port. |
| `APP_DB_NAME` | `mae_test` | Name of the application database to create and migrate. |
| `TEST_DB_NAME` | `test_db` | Database used by the pgTAP test suite. |
| `MAE_DB_NAME` | `mae` | Internal Mae system database name. |
| `SEARCH_PATH` | `app` | Default search path. Internal — do not override. |
| `SQLX_OFFLINE` | `true` | Run sqlx in offline mode (no live DB required for compilation). |
| `SUPERUSER` | `postgres` | Bootstrap superuser name. Used only by `sqlx_premigration.sh`. |
| `SUPERUSER_PWD` | `password` | Bootstrap superuser password. |
| `MIGRATOR_USER` | `db_migrator` | Login role for sqlx migrations (inherits `app_migrator`). |
| `MIGRATOR_PWD` | `migrator_secret` | Password for `MIGRATOR_USER`. |
| `APP_USER` | `app` | Login role for the application (inherits `app_user`). |
| `APP_USER_PWD` | `secret` | Password for `APP_USER`. |
| `TABLE_PROVISIONER_USER` | `table_provisioner` | Optional login role for runtime table creation (inherits `table_creator`). |
| `TABLE_PROVISIONER_PWD` | `provisioner_secret` | Password for `TABLE_PROVISIONER_USER`. |
| `PG_TEST_LOG` | _(unset)_ | Set to any value to stream Postgres logs to stdout (pgTAP container only). |
| `DEBUG` | _(unset)_ | Set to any value to enable verbose script logging. |
| `ENV_PATH` | _(unset)_ | Override the path to the `.env` file loaded by scripts. |
| `CONFIRM_IRREVOCABLE_DATABASE_WIPE` | _(unset)_ | See [Destructive reset guard](#️-destructive-reset-guard). |

---

## Key functions

All public functions live in the `app` schema. They are `SECURITY DEFINER` and enforce role-based access internally.

### `app.create_table_from_spec(p_spec jsonb) → void`

Creates a table in the `app` schema from a validated JSONB specification. This is the **only** supported way to create a table — raw `CREATE TABLE` is blocked by the DDL guard event trigger.

The function validates identifiers and column types, creates the table with standard system columns (`id`, `sys_client`, `status`, `comment`, `tags`, `sys_detail`, `created_by`, `updated_by`, `created_at`, `updated_at`), attaches the audit and immutable-column triggers, and calls `apply_table_acl`.

**Permitted callers:** members of `app_migrator`, `table_creator`, or `app_owner`.

```sql
SELECT app.create_table_from_spec('{
  "table_name": "my_table",
  "columns": [
    { "name": "title",    "type": "text", "nullable": false },
    { "name": "priority", "type": "int4", "default": 0     }
  ]
}'::jsonb);
```

---

### `app.apply_table_acl(p_table_name text, p_insertable_columns text[], p_updatable_columns text[]) → void`

Applies column-level ACLs to a table for `app_user`. Safe to re-run (idempotent). Use this in a later migration to harden a table — for example, to make certain columns insert-only by omitting them from the updatable list.

Revokes all existing privileges from `PUBLIC` and `app_user`, then grants `SELECT`, guarded `DELETE` (trigger fires immediately), column-scoped `INSERT`, and column-scoped `UPDATE`. Also updates the immutable-column policy in `mae._table_column_policies`.

---

### `app.drop_column(_tbl text, _col text) → void`

Drops a column from an `app`-schema table. Protected system columns (`id`, `sys_client`, `created_at`, `created_by`, `updated_at`, `updated_by`, `status`, `sys_detail`, `tags`) cannot be dropped. Automatically removes the column from the immutable-column policy.

**Permitted callers:** members of `app_migrator`, `table_creator`, or `app_owner`.

---

### `app.rename_column(_tbl text, _col text, _new_col text) → void`

Renames a column on an `app`-schema table. Protected system columns cannot be renamed.

**Permitted callers:** members of `app_migrator` or `table_creator`.

---

### `app.add_column_from_spec(p_spec jsonb) → void`

Adds a single column to an existing table using the same validated JSONB spec format as `create_table_from_spec`. Automatically re-applies ACLs after the column is added.

```sql
SELECT app.add_column_from_spec('{
  "table_name": "my_table",
  "column": { "name": "score", "type": "int4", "default": 0 }
}'::jsonb);
```

**Permitted callers:** members of `app_migrator`, `table_creator`, or `app_owner`.

---

### `app.upsert_table_column_policy(p_table_name text, p_immutable_columns text[]) → void`

Upserts the immutable-column policy for a table into `mae._table_column_policies`. This record is read by the `_enforce_immutable_columns` trigger to block `UPDATE` on insert-only columns.

Called automatically by `create_table_from_spec` and `apply_table_acl`. Call directly only when manually adjusting immutability policy outside of those functions.

---

### `app.apply_delete_guard(p_table_name text) → void`

Attaches the `_block_delete` trigger to a table. Called automatically by `apply_table_acl`. Any `DELETE` attempt raises:

```
Direct DELETE is not permitted. To remove a record, set its status to 'deleted' or 'archived' instead.
```

---

## Development setup

### Prerequisites

- Docker
- Git

### Clone and install hooks

```bash
git clone git@github.com:Mae-Technologies/postgres-mae.git
cd postgres-mae
bash scripts/install-hooks.sh   # installs pre-push pgTAP hook
```

The pre-push hook builds the image and runs the full pgTAP suite before every push. A push is rejected if any test fails.

### Run tests locally

```bash
docker build -t postgres-mae .

CID=$(docker run -d -e PG_TEST_LOG=1 postgres-mae)
docker logs -f "$CID"
```

The container exits after completing the test suite. Review the output for `pgTAP tests passed` or `PGTAP TESTS FAILED`.

Tests are run against four principals — `app_owner`, `app_migrator`, `app_user`, and `table_creator` — to verify that role boundaries are correctly enforced.

---

## ⚠️ Destructive reset guard

postgres-mae includes a hard safeguard against accidental database destruction. Under certain failure conditions the container can be configured to drop and recreate the database from scratch.

**This action is permanent and cannot be undone.**

| Variable | Safe value | Destructive value |
|---|---|---|
| `CONFIRM_IRREVOCABLE_DATABASE_WIPE` | _(unset)_ | `true` |

> **Warning:** Setting `CONFIRM_IRREVOCABLE_DATABASE_WIPE=true` will permanently destroy and recreate the database if the container encounters a critical failure. All data will be lost with no recovery path.
>
> - Do **not** set this variable in any deployed environment (`prod`, `stage`).
> - `APP_ENV` does **not** gate this behaviour — the flag must be set explicitly.
> - There is no confirmation prompt. The wipe happens immediately and automatically.

---

## License

MIT — see [LICENSE](LICENSE) *(pending issue #32)*
