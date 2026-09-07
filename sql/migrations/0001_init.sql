CREATE SCHEMA IF NOT EXISTS app;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='app_rw')     THEN CREATE ROLE app_rw     LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='app_ro')     THEN CREATE ROLE app_ro     LOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='n8n_ingest') THEN CREATE ROLE n8n_ingest LOGIN; END IF;
END $$;
ALTER ROLE app_rw     PASSWORD :'pw_app_rw';
ALTER ROLE app_ro     PASSWORD :'pw_app_ro';
ALTER ROLE n8n_ingest PASSWORD :'pw_n8n';
REVOKE ALL ON DATABASE ciplat FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;   -- no CREATE/USAGE on public for anyone by default; app roles only get schema app
GRANT CONNECT ON DATABASE ciplat TO app_rw, app_ro, n8n_ingest;
GRANT USAGE  ON SCHEMA app TO app_rw, app_ro, n8n_ingest;
CREATE TABLE IF NOT EXISTS app.documents (id bigserial PRIMARY KEY, source text, body text, ingested_at timestamptz DEFAULT now());
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA app TO app_rw;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO app_ro;
GRANT INSERT ON app.documents TO n8n_ingest;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA app TO app_rw, n8n_ingest;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT SELECT ON TABLES TO app_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA app GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
