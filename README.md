# PostgreSQL Database (dt3_bootcamp_database)

This repository contains the PostgreSQL schema and operational scripts for the **Commercial Energy Consumption Analytics & Anomaly Alerts** system.

## What this DB supports

Aligned to the PRD, the schema supports:

- **Ingestion**: store CSV upload metadata + interval meter readings (`timestamp`, `kWh`)
- **Dashboards**: query consumption trends and baseline vs actual
- **Baseline Calculation**: persist rolling 4-week average baseline per site/day
- **Anomaly Detection**: persist anomalies for days exceeding baseline by threshold (default 20%)
- **Alert Generation**: create alerts for account managers (status lifecycle: open/ack/resolved)
- **Peer Benchmarking**: store anonymised category average series
- **Exports**: store export job requests (CSV/PDF) and artifact metadata

> Compute logic (baseline/anomaly/benchmark generation) is expected to run in the backend service and write results here.

## Schema overview (tables)

### Dimensions
- `customers`: organisations (commercial customers)
- `sites`: customer sites/buildings (timezone stored; default UTC)
- `meters`: optional meter identifiers (extension point; safe to ignore initially)

### Ingestion
- `ingestion_uploads`: one row per CSV upload (row counts, error sample)
- `meter_readings`: high-volume interval readings (`ts`, `kwh`)

### Analytics persistence
- `daily_site_baselines`: per-site per-day baseline vs actual snapshots (rolling 4-week average baseline)
- `anomalies`: per-site per-day anomalies with deviation + suggested action + severity
- `alerts`: account-manager facing alerts with lifecycle status

### Benchmarking
- `category_benchmarks_daily`: anonymised peer average per category/day

### Exports
- `export_jobs`: requested date ranges + format + status
- `export_artifacts`: stored export file metadata (storage backend/key, checksum, size)

## Local bootstrap (example)

This repo includes scripts to create a dev role/database and apply the initial schema.

### 1) Create role + database (idempotent)

The `create_dev_user_db.sql` script uses `psql` variables:

- `app_user`
- `app_pass`
- `app_db`

Example:

```bash
sudo -u postgres psql -f PostgreSQLDatabase/scripts/create_dev_user_db.sql \
  -v app_user='energy_app' \
  -v app_pass='energy_app_password' \
  -v app_db='energy_analytics'
```

### 2) Apply schema

```bash
psql "postgresql://energy_app:energy_app_password@localhost:5432/energy_analytics" \
  -f PostgreSQLDatabase/scripts/001_init_schema.sql
```

### 3) Healthcheck

```bash
bash PostgreSQLDatabase/scripts/healthcheck.sh
```

## Notes / next steps

- Partitioning strategy for `meter_readings` (time-series) is intentionally deferred until volumes are known.
- Benchmarking methodology is TBD; schema provides a persistence structure for anonymised category averages.
- Authentication/user identity is TBD; `export_jobs.requested_by` is a placeholder field.
