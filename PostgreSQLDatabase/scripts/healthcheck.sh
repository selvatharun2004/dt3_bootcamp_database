#!/usr/bin/env bash
set -euo pipefail
WORKSPACE="${WORKSPACE:-/home/kavia/workspace/code-generation/dt3_bootcamp_database/PostgreSQLDatabase}"
: ${PGHOST:=127.0.0.1}; : ${PGPORT:=${PGPORT:-5432}}
pg_isready -h "$PGHOST" -p "$PGPORT" >/dev/null 2>&1 || exit 2
# superuser check
sudo -u postgres psql -h "$PGHOST" -p "$PGPORT" -U postgres -c 'SELECT 1' >/dev/null
