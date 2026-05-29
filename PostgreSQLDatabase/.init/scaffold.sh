#!/usr/bin/env bash
set -euo pipefail
WORKSPACE="${WORKSPACE:-/home/kavia/workspace/code-generation/dt3_bootcamp_database/PostgreSQLDatabase}"
DATA_DIR="$WORKSPACE/data"; CONF_DIR="$WORKSPACE/conf"; SCRIPTS_DIR="$WORKSPACE/scripts"
# ensure dirs
sudo mkdir -p "$DATA_DIR" "$CONF_DIR" "$SCRIPTS_DIR" && sudo chown -R postgres:postgres "$DATA_DIR" "$CONF_DIR" "$SCRIPTS_DIR"
# source persisted env if present
[ -f /etc/profile.d/pg_dev_env.sh ] && source /etc/profile.d/pg_dev_env.sh || true
: ${PGPORT:=5432}
# initdb if absent
sudo -u postgres bash -lc "[ -s '$DATA_DIR/PG_VERSION' ] || initdb -D '$DATA_DIR' --username=postgres --auth=trust >/dev/null"
# write minimal postgresql.conf if missing
if [ ! -f "$CONF_DIR/postgresql.conf" ]; then
  sudo bash -lc "cat > '$CONF_DIR/postgresql.conf' <<EOF
listen_addresses = '*'
port = ${PGPORT}
logging_collector = off
log_min_messages = warning
shared_buffers = 32MB
max_connections = 50
EOF"
fi
# verify port consistency
conf_port=$(grep -E '^\s*port\s*=\s*' "$CONF_DIR/postgresql.conf" | sed -E 's/[^0-9]*([0-9]+).*/\1/') || conf_port=""
if [ -n "$conf_port" ] && [ "$conf_port" != "${PGPORT}" ]; then echo "PGPORT mismatch: env=${PGPORT} conf=${conf_port}" >&2; exit 3; fi
# write pg_hba.conf if missing (dev: trust)
if [ ! -f "$CONF_DIR/pg_hba.conf" ]; then
  sudo bash -lc "cat > '$CONF_DIR/pg_hba.conf' <<EOF
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    all             all             ::1/128                 trust
EOF"
fi
sudo chown -R postgres:postgres "$CONF_DIR"
# create idempotent SQL template (non-executable) for creating role and DB
if [ ! -f "$SCRIPTS_DIR/create_dev_user_db.sql" ]; then
  cat > "$SCRIPTS_DIR/create_dev_user_db.sql" <<'SQL'
-- idempotent user/db creation
-- variables: :app_user, :app_pass, :app_db
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') THEN
    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_pass');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_db') THEN
    EXECUTE format('CREATE DATABASE %I OWNER %I', :'app_db', :'app_user');
  END IF;
END$$;
SQL
  sudo chown postgres:postgres "$SCRIPTS_DIR/create_dev_user_db.sql"
fi
# runner: execute SQL template as postgres (uses trust auth)
cat > "$SCRIPTS_DIR/run_create_user_db.sh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
WORKSPACE="${WORKSPACE:-/home/kavia/workspace/code-generation/dt3_bootcamp_database/PostgreSQLDatabase}"
SCRIPTS_DIR="$WORKSPACE/scripts"
: ${PGUSER:=devuser}; : ${PGDATABASE:=devdb}; : ${PGPASSWORD:=devpass}; : ${PGPORT:=5432}
# run idempotent SQL as postgres superuser; uses trust auth on local port
sudo -u postgres psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PGPORT" -U postgres -f "$SCRIPTS_DIR/create_dev_user_db.sql" -v app_user="$PGUSER" -v app_pass="$PGPASSWORD" -v app_db="$PGDATABASE"
BASH
chmod 750 "$SCRIPTS_DIR/run_create_user_db.sh"
sudo chown postgres:postgres "$SCRIPTS_DIR/run_create_user_db.sh"
# done
