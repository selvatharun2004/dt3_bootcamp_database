#!/usr/bin/env bash
set -euo pipefail
WORKSPACE="${WORKSPACE:-/home/kavia/workspace/code-generation/dt3_bootcamp_database/PostgreSQLDatabase}"
DATA_DIR="$WORKSPACE/data"; CONF_DIR="$WORKSPACE/conf"
[ -f /etc/profile.d/pg_dev_env.sh ] && source /etc/profile.d/pg_dev_env.sh || true
: ${PGPORT:=5432}
# Run healthcheck (relies on scripts/healthcheck.sh created earlier)
sudo -u postgres "$WORKSPACE/scripts/healthcheck.sh"
# If a dump exists, validate pg_restore tooling by listing contents
if [ -f "$WORKSPACE/devdb.dump" ]; then sudo -u postgres pg_restore -l "$WORKSPACE/devdb.dump" >/dev/null; fi
