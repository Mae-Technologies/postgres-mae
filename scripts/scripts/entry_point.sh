#!/usr/bin/env bash
set -euo pipefail

export PGDATA=/var/lib/postgresql/data
export PATH="/usr/lib/postgresql/18/bin:$PATH"

# Fix ownership at runtime (Docker volumes mount as root)
chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

# Init cluster if empty
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "▶ Initializing PostgreSQL cluster..."
  su -s /bin/bash postgres -c "initdb -D $PGDATA"
fi

# Allow all connections from Docker network (trust for internal use)
cat > "$PGDATA/pg_hba.conf" << HBAEOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             172.0.0.0/8             md5
host    all             all             ::1/128                 trust
HBAEOF

echo "▶ Starting PostgreSQL..."
su -s /bin/bash postgres -c "pg_ctl -D $PGDATA -o \"-p ${DB_PORT}\" -w start"

until pg_isready -U "${SUPERUSER}" -p "${DB_PORT}"; do
  echo "Waiting for PostgreSQL..."
  sleep 1
done

echo "▶ Bootstrapping users and databases..."
bash /workspace/scripts/sqlx_premigration.sh

echo "▶ Running migrations..."
bash /workspace/scripts/run.sh

echo "▶ postgres-mae ready ✓"
tail -f /dev/null
