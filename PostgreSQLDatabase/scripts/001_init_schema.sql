-- Commercial Energy Consumption Analytics & Anomaly Alerts
-- Initial database schema (v1).
--
-- This script is intended to be idempotent and safe to re-run.
-- It creates the core tables required for:
-- - CSV ingestion of meter readings
-- - Rolling baseline storage (4-week average)
-- - Anomaly detection storage
-- - Alert generation and lifecycle tracking
-- - Peer benchmarking aggregates (anonymised category averages)
-- - Export jobs + downloaded artifacts metadata
--
-- Note: Actual compute logic (baseline/anomaly) happens in the backend; this schema
-- provides persistence and queryable structures.

BEGIN;

-- Ensure required extensions exist.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- Migration tracking (lightweight)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Record this migration (idempotent).
INSERT INTO schema_migrations(version)
VALUES ('001_init_schema')
ON CONFLICT (version) DO NOTHING;

-- -----------------------------------------------------------------------------
-- Reference / dimension tables
-- -----------------------------------------------------------------------------

-- Customers represent organisations (commercial energy customers).
CREATE TABLE IF NOT EXISTS customers (
  customer_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  business_category TEXT NULL, -- Used for peer benchmarking groups (e.g., logistics, retail); may evolve.
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT customers_name_uniq UNIQUE (name)
);

-- Sites represent physical sites/buildings/plants per customer.
CREATE TABLE IF NOT EXISTS sites (
  site_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES customers(customer_id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  timezone TEXT NOT NULL DEFAULT 'UTC',
  business_category TEXT NULL, -- Optional override for site-level categorisation.
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT sites_customer_name_uniq UNIQUE (customer_id, name)
);

-- Optional: meters (TBD in PRD, but included as a pragmatic extension point).
-- If not used, readings can still be stored with meter_id NULL.
CREATE TABLE IF NOT EXISTS meters (
  meter_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id UUID NOT NULL REFERENCES sites(site_id) ON DELETE CASCADE,
  external_meter_ref TEXT NULL, -- Back-office meter identifier if/when available.
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT meters_site_external_ref_uniq UNIQUE (site_id, external_meter_ref)
);

-- -----------------------------------------------------------------------------
-- Ingestion: raw uploads and readings
-- -----------------------------------------------------------------------------

-- Tracks an ingestion upload event (CSV file metadata & outcome).
CREATE TABLE IF NOT EXISTS ingestion_uploads (
  upload_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id UUID NOT NULL REFERENCES sites(site_id) ON DELETE CASCADE,
  original_filename TEXT NOT NULL,
  content_type TEXT NULL,
  file_sha256 TEXT NULL, -- optional dedupe aid
  rows_received INTEGER NOT NULL DEFAULT 0,
  rows_accepted INTEGER NOT NULL DEFAULT 0,
  rows_rejected INTEGER NOT NULL DEFAULT 0,
  error_sample TEXT[] NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- High-volume time-series readings.
-- Stored at timestamp granularity (interval readings). Daily aggregates can be computed via queries/jobs.
CREATE TABLE IF NOT EXISTS meter_readings (
  reading_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id UUID NOT NULL REFERENCES sites(site_id) ON DELETE CASCADE,
  meter_id UUID NULL REFERENCES meters(meter_id) ON DELETE SET NULL,
  upload_id UUID NULL REFERENCES ingestion_uploads(upload_id) ON DELETE SET NULL,
  ts TIMESTAMPTZ NOT NULL,
  kwh DOUBLE PRECISION NOT NULL CHECK (kwh >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Prevent duplicates for the same site+meter+timestamp. (If meter_id is NULL, uniqueness is still enforced per-site.)
CREATE UNIQUE INDEX IF NOT EXISTS meter_readings_site_meter_ts_uniq
  ON meter_readings(site_id, COALESCE(meter_id, '00000000-0000-0000-0000-000000000000'::uuid), ts);

CREATE INDEX IF NOT EXISTS meter_readings_site_ts_idx ON meter_readings(site_id, ts);

-- -----------------------------------------------------------------------------
-- Baselines (rolling 4-week average per site, per day bucket)
-- -----------------------------------------------------------------------------

-- Stores per-day computed baseline and actual totals.
-- Baseline computation: rolling 4-week average (per PRD). Stored by backend jobs.
CREATE TABLE IF NOT EXISTS daily_site_baselines (
  site_id UUID NOT NULL REFERENCES sites(site_id) ON DELETE CASCADE,
  day DATE NOT NULL,
  actual_kwh DOUBLE PRECISION NOT NULL CHECK (actual_kwh >= 0),
  baseline_kwh DOUBLE PRECISION NOT NULL CHECK (baseline_kwh >= 0),
  deviation_pct DOUBLE PRECISION NOT NULL, -- (actual-baseline)/baseline*100
  threshold_pct DOUBLE PRECISION NOT NULL DEFAULT 20.0, -- the threshold used for anomaly flagging
  computed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (site_id, day)
);

CREATE INDEX IF NOT EXISTS daily_site_baselines_day_idx ON daily_site_baselines(day);

-- -----------------------------------------------------------------------------
-- Anomalies (day-level deviations beyond threshold)
-- -----------------------------------------------------------------------------

CREATE TYPE IF NOT EXISTS anomaly_severity AS ENUM ('medium', 'high');

CREATE TABLE IF NOT EXISTS anomalies (
  anomaly_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id UUID NOT NULL REFERENCES sites(site_id) ON DELETE CASCADE,
  day DATE NOT NULL,
  deviation_pct DOUBLE PRECISION NOT NULL,
  threshold_pct DOUBLE PRECISION NOT NULL DEFAULT 20.0,
  severity anomaly_severity NOT NULL,
  suggested_action TEXT NOT NULL,
  detected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- link to baseline snapshot for transparency/auditing
  baseline_kwh DOUBLE PRECISION NULL,
  actual_kwh DOUBLE PRECISION NULL,
  CONSTRAINT anomalies_site_day_uniq UNIQUE (site_id, day)
);

CREATE INDEX IF NOT EXISTS anomalies_site_day_idx ON anomalies(site_id, day);
CREATE INDEX IF NOT EXISTS anomalies_detected_at_idx ON anomalies(detected_at);

-- -----------------------------------------------------------------------------
-- Alerts (account manager dashboard)
-- -----------------------------------------------------------------------------

CREATE TYPE IF NOT EXISTS alert_status AS ENUM ('open', 'acknowledged', 'resolved');

-- Alerts are created when anomalies are detected (per PRD).
-- We keep denormalized customer/site names out; they can be joined via sites/customers.
CREATE TABLE IF NOT EXISTS alerts (
  alert_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  anomaly_id UUID NULL REFERENCES anomalies(anomaly_id) ON DELETE SET NULL,
  site_id UUID NOT NULL REFERENCES sites(site_id) ON DELETE CASCADE,
  day DATE NOT NULL,
  deviation_pct DOUBLE PRECISION NOT NULL,
  suggested_action TEXT NOT NULL,
  severity anomaly_severity NOT NULL,
  status alert_status NOT NULL DEFAULT 'open',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  acknowledged_at TIMESTAMPTZ NULL,
  resolved_at TIMESTAMPTZ NULL,
  CONSTRAINT alerts_site_day_uniq UNIQUE (site_id, day)
);

CREATE INDEX IF NOT EXISTS alerts_status_created_at_idx ON alerts(status, created_at DESC);
CREATE INDEX IF NOT EXISTS alerts_site_day_idx ON alerts(site_id, day);

-- -----------------------------------------------------------------------------
-- Benchmarking (anonymised category averages)
-- -----------------------------------------------------------------------------

-- Stores anonymised peer average consumption for a category and day bucket.
-- Methodology is TBD; this table supports the customer dashboard comparison.
CREATE TABLE IF NOT EXISTS category_benchmarks_daily (
  business_category TEXT NOT NULL,
  day DATE NOT NULL,
  peer_avg_kwh DOUBLE PRECISION NOT NULL CHECK (peer_avg_kwh >= 0),
  computed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (business_category, day)
);

CREATE INDEX IF NOT EXISTS category_benchmarks_daily_day_idx ON category_benchmarks_daily(day);

-- -----------------------------------------------------------------------------
-- Exports (CSV/PDF)
-- -----------------------------------------------------------------------------

CREATE TYPE IF NOT EXISTS export_format AS ENUM ('csv', 'pdf');
CREATE TYPE IF NOT EXISTS export_status AS ENUM ('queued', 'running', 'complete', 'failed');

CREATE TABLE IF NOT EXISTS export_jobs (
  job_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  site_id UUID NOT NULL REFERENCES sites(site_id) ON DELETE CASCADE,
  requested_by TEXT NULL, -- user identifier/email (auth TBD)
  start_date DATE NOT NULL,
  end_date DATE NOT NULL,
  format export_format NOT NULL,
  status export_status NOT NULL DEFAULT 'queued',
  error_message TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at TIMESTAMPTZ NULL,
  completed_at TIMESTAMPTZ NULL,
  CONSTRAINT export_jobs_date_range_chk CHECK (end_date >= start_date)
);

CREATE INDEX IF NOT EXISTS export_jobs_site_created_at_idx ON export_jobs(site_id, created_at DESC);
CREATE INDEX IF NOT EXISTS export_jobs_status_created_at_idx ON export_jobs(status, created_at DESC);

-- Metadata for stored export artifacts (file key/path, content type, size).
CREATE TABLE IF NOT EXISTS export_artifacts (
  artifact_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id UUID NOT NULL REFERENCES export_jobs(job_id) ON DELETE CASCADE,
  storage_backend TEXT NOT NULL DEFAULT 'local', -- future: s3, gcs, etc.
  storage_key TEXT NOT NULL, -- path/key in chosen backend
  content_type TEXT NOT NULL,
  byte_size BIGINT NULL CHECK (byte_size IS NULL OR byte_size >= 0),
  sha256 TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT export_artifacts_job_key_uniq UNIQUE (job_id, storage_key)
);

COMMIT;
