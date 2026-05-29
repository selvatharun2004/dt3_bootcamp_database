#!/usr/bin/env bash
set -euo pipefail
WORKSPACE="${WORKSPACE:-/home/kavia/workspace/code-generation/dt3_bootcamp_database/PostgreSQLDatabase}"
DATA_DIR="$WORKSPACE/data"; CONF_DIR="$WORKSPACE/conf"
[ -f /etc/profile.d/pg_dev_env.sh ] && source /etc/profile.d/pg_dev_env.sh || true
: ${PGPORT:=5432}
# Start server briefly
sudo -u postgres pg_ctl -D "$DATA_DIR" -o "-c config_file=$CONF_DIR/postgresql.conf -c hba_file=$CONF_DIR/pg_hba.conf" -w start
for i in 1 2 3 4 5; do sudo -u postgres pg_isready -p "$PGPORT" >/dev/null 2>&1 && break || sleep 1; if [ "$i" -eq 5 ]; then echo "validation: postgres not ready" >&2; sudo -u postgres pg_ctl -D "$DATA_DIR" -w stop || true; exit 5; fi; done
# Run healthcheck
sudo -u postgres "$WORKSPACE/scripts/healthcheck.sh"
# Validate restore tooling if dump exists
if [ -f "$WORKSPACE/devdb.dump" ]; then sudo -u postgres pg_restore -l "$WORKSPACE/devdb.dump" >/dev/null; fi
# Stop server
sudo -u postgres pg_ctl -D "$DATA_DIR" -w stop
echo "validation: OK"
