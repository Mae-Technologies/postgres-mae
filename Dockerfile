FROM postgres:18

USER root

RUN set -eux; \
  apt-get update; \
  apt-get install -y --no-install-recommends \
    ca-certificates curl bash uuid-runtime \
    build-essential pkg-config libssl-dev; \
  rm -rf /var/lib/apt/lists/*

RUN set -eux; \
  curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; \
  . /root/.cargo/env; \
  cargo install --version "~0.8" sqlx-cli --no-default-features --features rustls,postgres; \
  ln -sf /root/.cargo/bin/sqlx /usr/local/bin/sqlx

WORKDIR /workspace
COPY .env /workspace/.env
COPY scripts/ /workspace/scripts/
COPY migrations/ /workspace/migrations/

RUN chmod +x /workspace/scripts/entry_point.sh \
             /workspace/scripts/run.sh \
             /workspace/scripts/sqlx_premigration.sh

# Give postgres user ownership of its data dir at image build time
RUN install -d -m 0700 -o postgres -g postgres /var/lib/postgresql/data

ENTRYPOINT ["/workspace/scripts/entry_point.sh"]
