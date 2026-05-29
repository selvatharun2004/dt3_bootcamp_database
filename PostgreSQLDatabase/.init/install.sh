#!/usr/bin/env bash
set -euo pipefail
WORKSPACE="${WORKSPACE:-/home/kavia/workspace/code-generation/dt3_bootcamp_database/PostgreSQLDatabase}"
sudo mkdir -p "$WORKSPACE" && sudo chown -R $(id -u):$(id -g) "$WORKSPACE"
: ${PGDATABASE:=devdb}
: ${PGUSER:=devuser}
: ${PGPORT:=5432}
if ss -ltn '( sport = :5432 )' | grep -q LISTEN; then PGPORT=$(shuf -i 20000-30000 -n1); fi
sudo bash -c "cat > /etc/profile.d/pg_dev_env.sh <<'EOF'
export PGDATABASE='${PGDATABASE}'
export PGUSER='${PGUSER}'
export PGPORT='${PGPORT}'
EOF"
sudo chown root:root /etc/profile.d/pg_dev_env.sh && sudo chmod 644 /etc/profile.d/pg_dev_env.sh
command -v psql >/dev/null && command -v pg_dump >/dev/null && command -v pg_restore >/dev/null || { echo "Missing postgres CLIs" >&2; exit 2; }
