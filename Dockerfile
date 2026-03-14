FROM postgres:16-bookworm

USER root

# ----------------------------
# System deps: pgtap + tooling
# Pin postgresql-client-16 to avoid generic 'postgresql-client' metapackage
# pulling in the latest postgres version (18+) and causing pg_config confusion.
# ----------------------------
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    bash \
    uuid-runtime \
    perl \
    postgresql-common \
    postgresql-client-16 \
  ; \
  rm -rf /var/lib/apt/lists/*

# ----------------------------
# pgTAP runner (pg_prove) + Postgres TAP handler
# Install postgresql-16-pgtap explicitly rather than detecting dynamically,
# since the generic 'postgresql-client' metapackage can install a newer
# Postgres version, causing pg_config to report the wrong PG_MAJOR.
# ----------------------------
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    libtap-parser-sourcehandler-pgtap-perl \
    postgresql-16-pgtap \
  ; \
  rm -rf /var/lib/apt/lists/*

# ----------------------------
# Podman — daemonless container runtime for CI sidecars (e.g. neo4j).
# Used by mae-integration-task to run neo4j:5 alongside postgres without DinD.
# ----------------------------
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    podman \
  ; \
  rm -rf /var/lib/apt/lists/*

# ----------------------------
# Migration strategy: psql + ordered SQL files (no sqlx-cli)
#
# sqlx-cli has no prebuilt binaries and must be compiled from source via
# rustup + cargo, adding ~10-15 minutes to every Docker build. Since our
# migrations are plain .sql files and already use CREATE OR REPLACE /
# IF NOT EXISTS (idempotent), we replace sqlx with a psql-based runner
# that applies files in sorted order and tracks them in mae._migrations.
# This keeps the image lean and the build fast.
# ----------------------------

# ----------------------------
# Workspace + copy repo bits
# ----------------------------
WORKDIR /workspace

COPY .env /workspace/.env
COPY scripts/ /workspace/scripts/
COPY migrations/ /workspace/migrations/
COPY tests/ /workspace/tests/

RUN chmod +x /workspace/scripts/entry_point.sh
RUN chmod +x /workspace/scripts/run.sh
RUN chmod +x /workspace/scripts/sqlx_premigration.sh
RUN chmod +x /workspace/scripts/run_tests.sh

# ----------------------------
# Healthcheck:
# Returns healthy only if Postgres is accepting connections AND the
# /tmp/postgres_init_done sentinel file exists (written by run.sh after
# all init scripts complete successfully). This ensures the healthcheck
# returns FAIL if SQL scripts haven't finished or failed mid-run.
# ----------------------------
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=5 \
  CMD pg_isready -h "${DB_HOST:-127.0.0.1}" -p "${DB_PORT:-2345}" -U "${SUPERUSER:-postgres}" \
      && test -f /tmp/postgres_init_done

ENTRYPOINT ["/workspace/scripts/entry_point.sh"]
