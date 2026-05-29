-- idempotent template: creates role and database if missing
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user') THEN
    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', :'app_user', :'app_pass');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'app_db') THEN
    EXECUTE format('CREATE DATABASE %I OWNER %I', :'app_db', :'app_user');
  END IF;
END$$;
