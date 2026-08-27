-- The roles the pipeline connects as, the schema they own, and the grants.
--
-- Run as the RDS master user — the one RDS gives `rds_superuser`. This is the
-- half of the bootstrap that has to come before anything owns anything, so it
-- sorts first: `db-init` applies it ahead of the rest, and `db-bootstrap`
-- applies it too and then sets the password.
--
-- What is deliberately not here:
--
--   the extensions   `001_extensions.sql` owns those, `vector` included.
--   the database     `CREATE DATABASE` cannot run inside a transaction block,
--                    and this file is meant to be re-run. The instance creates
--                    it (`db_name`, default `urban_rag`).
--   the password     `db.py bootstrap` generates one, sets it, and writes it
--                    to the Secrets Manager secret Terraform made for it — so
--                    it lives in one place and never in a file. A role created
--                    here and never bootstrapped simply cannot log in yet.
--
-- Idempotent throughout: db.py applies every file in sql/ on each `db-init`.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. The roles
--
-- `urban_rag` is what the pipeline and the query side connect as; it owns the
-- `rag` schema plus Dagster's metadata schema. `urban_rag_ro` is the read-only
-- half, for anything that reads the corpus without loading it.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'urban_rag') THEN
        CREATE ROLE urban_rag LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'urban_rag_ro') THEN
        CREATE ROLE urban_rag_ro LOGIN;
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 2. The master user has to be able to SET ROLE to urban_rag
--
-- PostgreSQL 16 gives the creating role ADMIN on a role it creates but not SET
-- — `createrole_self_grant` defaults to empty — and on RDS the master user is
-- rds_superuser, not a superuser, so nothing else fills the gap. Without SET,
-- the `CREATE SCHEMA ... AUTHORIZATION` below fails with `must be able to SET
-- ROLE "urban_rag"`, and so does every `ALTER ... OWNER TO urban_rag` in the
-- files after this one. INHERIT is what keeps the master able to create in the
-- schema it has just handed over, which is what re-running those needs.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF current_setting('server_version_num')::int >= 160000 THEN
        EXECUTE format('GRANT urban_rag TO %I WITH INHERIT TRUE, SET TRUE', CURRENT_USER);
    ELSE
        EXECUTE format('GRANT urban_rag TO %I', CURRENT_USER);
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. The schemas, owned by the pipeline's role
--
-- Owned by it so it can create its own tables and indexes there without any
-- further grant — `rag.chunks` and its HNSW index are created by the
-- dataplatform on first load, not here, and so is every partition of a
-- `silver`/`gold` table (see 003_warehouse.sql). Everything this repo's own
-- files create is handed to the same owner at the end of each file.
--
-- Four schemas, and the split between them is the medallion layer:
--
--   rag        the spatial working set the PostGIS joins are computed over —
--              rag.lots, rag.buildings, rag.features — plus the vector corpus
--              rag.chunks. Bronze loads and the index built on them.
--   silver     one table per silver dataset, partitioned by neighborhood and
--              scrape date. 004, 005, 007, 008, 010, 011, 012.
--   gold       the same, for gold. 009.
--   warehouse  no data: the one function that creates a silver/gold partition
--              on demand, so the pipeline never has to be told about a new
--              borough or a new month twice.
--   dagster    Dagster's own run/event metadata, which it creates and migrates
--              itself.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS rag AUTHORIZATION urban_rag;
CREATE SCHEMA IF NOT EXISTS silver AUTHORIZATION urban_rag;
CREATE SCHEMA IF NOT EXISTS gold AUTHORIZATION urban_rag;
CREATE SCHEMA IF NOT EXISTS warehouse AUTHORIZATION urban_rag;
CREATE SCHEMA IF NOT EXISTS dagster AUTHORIZATION urban_rag;

-- A schema created before this block existed is master-owned; hand it over so
-- re-running this file repairs it rather than only fixing new databases.
DO $$
DECLARE
    schema_name text;
BEGIN
    FOREACH schema_name IN ARRAY ARRAY['rag', 'silver', 'gold', 'warehouse'] LOOP
        EXECUTE format('ALTER SCHEMA %I OWNER TO urban_rag', schema_name);
    END LOOP;
END
$$;

ALTER SCHEMA dagster OWNER TO urban_rag;
REVOKE ALL ON SCHEMA dagster FROM PUBLIC;

-- Dagster creates *and migrates* its own tables here, and which role does it
-- decides what can happen to them afterwards. Owning the schema is not enough.
-- A run pointed at this database with the master credentials — what `db.py env`
-- without --app hands out — leaves every table owned by the master user, and a
-- later run as `urban_rag` can then read and write them but cannot run the
-- `ALTER TABLE` its own alembic migrations issue on a Dagster upgrade. A grant
-- does not fix that: ALTER needs ownership, not privileges.
--
-- So hand them over, the way 002_spatial.sql does for `rag` — which also means
-- re-running `db-init` repairs an instance that was already started the wrong
-- way round. Indexes follow their table's owner and need no case of their own.
DO $$
DECLARE
    obj record;
BEGIN
    FOR obj IN
        SELECT c.relkind, c.oid::regclass AS name
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'dagster'
           AND c.relkind IN ('r', 'S', 'v', 'm')
           AND c.relowner <> 'urban_rag'::regrole
    LOOP
        EXECUTE format(
            '%s %s OWNER TO urban_rag',
            CASE obj.relkind
                WHEN 'r' THEN 'ALTER TABLE'
                WHEN 'S' THEN 'ALTER SEQUENCE'
                WHEN 'v' THEN 'ALTER VIEW'
                WHEN 'm' THEN 'ALTER MATERIALIZED VIEW'
            END,
            obj.name
        );
    END LOOP;
END
$$;

-- And the same for a table the master user creates *between* two runs of this
-- file: it stays master-owned until the next `db-init`, so grant on it now.
-- No FOR ROLE, so this applies to CURRENT_USER — the master user running this.
ALTER DEFAULT PRIVILEGES IN SCHEMA dagster GRANT ALL ON TABLES TO urban_rag;
ALTER DEFAULT PRIVILEGES IN SCHEMA dagster GRANT ALL ON SEQUENCES TO urban_rag;

-- The read-only half, over every schema that holds data. `warehouse` is left
-- out: it holds a function that creates tables, which is not something a
-- reader has any business calling.
DO $$
DECLARE
    schema_name text;
BEGIN
    FOREACH schema_name IN ARRAY ARRAY['rag', 'silver', 'gold'] LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO urban_rag_ro', schema_name);
        -- Most of the tables do not exist yet, so the grant is on what gets
        -- created later ...
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES FOR ROLE urban_rag IN SCHEMA %I '
            'GRANT SELECT ON TABLES TO urban_rag_ro', schema_name);
        -- ... and on anything an earlier run or a first load already created.
        EXECUTE format(
            'GRANT SELECT ON ALL TABLES IN SCHEMA %I TO urban_rag_ro',
            schema_name);
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 4. Nothing else in this database is any of their business
-- ---------------------------------------------------------------------------
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO urban_rag, urban_rag_ro;

COMMIT;

-- IAM authentication, which is what URBAN_RAG_PG_IAM_AUTH=1 expects, instead
-- of the password `db.py bootstrap` sets. The token is signed by AWS and valid
-- for fifteen minutes, so nothing long-lived is stored anywhere. The IAM
-- policy on the task role also has to allow rds-db:connect on
--   arn:aws:rds-db:<region>:<account>:dbuser:<db-resource-id>/urban_rag
-- which ssm.tf already writes. Uncomment to switch:
--
--   GRANT rds_iam TO urban_rag;
--   GRANT rds_iam TO urban_rag_ro;
