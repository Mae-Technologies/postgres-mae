FROM postgres:18

USER root

# ----------------------------
# System deps: pgtap + tooling
# ----------------------------
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    bash \
    uuid-runtime \
    build-essential \
    pkg-config \
    libssl-dev \
    perl \
    postgresql-common \
    docker.io \
  ; \
  rm -rf /var/lib/apt/lists/*

# ----------------------------
# pgTAP runner (pg_prove) + Postgres TAP handler
# ----------------------------
RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    postgresql-client \
    libtap-parser-sourcehandler-pgtap-perl \
  ; \
  rm -rf /var/lib/apt/lists/*

# Install pgTAP matching this Postgres major version
RUN set -eux; \
  PG_MAJOR="$(pg_config --version | awk '{print $2}' | cut -d. -f1)"; \
  apt-get update; \
  apt-get install -y --no-install-recommends "postgresql-${PG_MAJOR}-pgtap"; \
  rm -rf /var/lib/apt/lists/*

# ----------------------------
# Install sqlx-cli (your script uses it)
# ----------------------------
RUN set -eux; \
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; \
  . /root/.cargo/env; \
  cargo install --version "~0.8" sqlx-cli --no-default-features --features rustls,postgres; \
  ln -sf /root/.cargo/bin/sqlx /usr/local/bin/sqlx

# ----------------------------
# Workspace + copy repo bits
# ----------------------------
WORKDIR /workspace

COPY .env /workspace/.env
COPY scripts/ /workspace/scripts/
COPY migrations/ /workspace/migrations/
COPY tests/ /workspace/tests/

RUN chmod +x /workspace/scripts/run.sh
RUN chmod +x /workspace/scripts/sqlx_premigration.sh

ENTRYPOINT ["/workspace/scripts/run.sh"]
