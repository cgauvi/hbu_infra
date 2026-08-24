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
-- 3. The schema, owned by the pipeline's role
--
-- Owned by it so it can create its own tables and indexes there without any
-- further grant — `rag.chunks` and its HNSW index are created by the
-- dataplatform on first load, not here. Everything this repo's own files
-- create in `rag` is handed to the same owner at the end of each file.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS rag AUTHORIZATION urban_rag;
CREATE SCHEMA IF NOT EXISTS dagster AUTHORIZATION urban_rag;

ALTER SCHEMA dagster OWNER TO urban_rag;
REVOKE ALL ON SCHEMA dagster FROM PUBLIC;

GRANT USAGE ON SCHEMA rag TO urban_rag_ro;
-- Most of the tables do not exist yet, so the grant is on what gets created
-- later ...
ALTER DEFAULT PRIVILEGES FOR ROLE urban_rag IN SCHEMA rag
    GRANT SELECT ON TABLES TO urban_rag_ro;
-- ... and on anything an earlier run or a first load already created.
GRANT SELECT ON ALL TABLES IN SCHEMA rag TO urban_rag_ro;

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
