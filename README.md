# postgres-mae

Custom Postgres image for Mae-Technologies, with schema migrations and [pgTAP](https://pgtap.org/) tests.

## Purpose

This repo focuses on **build and test correctness** — schema migrations are verified via pgTAP. The git hook runs pgTAP tests locally before commits are accepted.

## Publishing

Image publishing is handled by the [`Mae-Technologies/concourse_ci`](https://github.com/Mae-Technologies/concourse_ci) pipeline (see [concourse_ci#51](https://github.com/Mae-Technologies/concourse_ci/issues/51)). This repo does **not** manage image publishing or GHCR automation.

## Development Setup

After cloning, install the git hooks:

```bash
bash scripts/install-hooks.sh
```

This runs pgTAP tests locally before every push. Pushes are blocked if tests fail.

## ⚠️ Destructive Reset Guard

**`CONFIRM_IRREVOCABLE_DATABASE_WIPE`** — controls whether a critical container failure
triggers a full database drop and recreate.

| Value | Behaviour |
|-------|-----------|
| unset / `false` | **Safe (default).** On failure, the container halts and waits for a reload. Data is preserved. |
| `true` | **DANGER.** The database is permanently and irrecoverably destroyed and recreated. |

Previously, `APP_ENV=test` implicitly triggered destructive resets. That behaviour has been
removed entirely. `APP_ENV` now only controls non-destructive settings (log verbosity, exit
behaviour). Destroying the database requires explicit intent via this flag.

**Rules:**
- Leave this unset or `false` in all deployed environments (staging, prod, etc.)
- Only set to `true` in isolated local dev / CI environments where data loss is acceptable
- There is **no undo** — all data in the database will be gone

```bash
# docker-compose.yml — add under environment: (commented out = safe)
# CONFIRM_IRREVOCABLE_DATABASE_WIPE: "false"

# .env — add (commented out = safe)
# CONFIRM_IRREVOCABLE_DATABASE_WIPE=false
```

## Sources

- https://pgtap.org/documentation.html#has_column
- https://pgpedia.info/search.html
