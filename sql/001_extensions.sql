-- Extensions. Run once per database, as the RDS master user — the role RDS
-- gives rds_superuser, which is what CREATE EXTENSION requires here.
--
-- The `urban_rag` login role, the `rag`/`dagster` schemas it owns, and the
-- grants live in 000_roles.sql, which sorts before this file and has therefore
-- already run by the time this one does. `vector` is created here rather than
-- there because extensions are one thing and roles are another.
--
-- IF NOT EXISTS throughout, so this is safe to re-run: db.py applies every
-- file in sql/ in name order on each `db-init`.

-- Geometry, geography, and the GiST operator classes that index them. The
-- reason this database is RDS Postgres rather than a vector store: the corpus
-- answers "what do the rules say", and PostGIS answers "which rules apply
-- here". Neither question is useful on its own.
CREATE EXTENSION IF NOT EXISTS postgis;

-- Vector type, distance operators, and HNSW. Kept here with the other
-- privileged database setup; the dataplatform creates only its own tables and
-- indexes once the extension exists.
CREATE EXTENSION IF NOT EXISTS vector;

-- Trigram similarity — the lexical half of hybrid retrieval, and what lets an
-- ILIKE over chunk text use an index instead of reading the corpus.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Query statistics. RDS preloads the library on postgres16 by default; this
-- makes the view visible inside this database.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
