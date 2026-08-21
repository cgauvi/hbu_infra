-- Extensions. Run once per database, as the RDS master user — the role RDS
-- gives rds_superuser, which is what CREATE EXTENSION requires here.
--
-- This is the half of the bootstrap that infrastructure owns. The other half —
-- the `urban_rag` login role, the `rag` schema it owns, and the grants — lives
-- in the dataplatform's sql/pgvector_bootstrap.sql, because that is the repo
-- whose code connects as that role. `make db-bootstrap` runs it from here.
--
-- IF NOT EXISTS throughout, so this is safe to re-run: db.py applies every
-- file in sql/ in name order on each `db-init`.

-- Geometry, geography, and the GiST operator classes that index them. The
-- reason this database is RDS Postgres rather than a vector store: the corpus
-- answers "what do the rules say", and PostGIS answers "which rules apply
-- here". Neither question is useful on its own.
CREATE EXTENSION IF NOT EXISTS postgis;

-- Vector type, distance operators, and HNSW. Also created by the
-- dataplatform's bootstrap; created here too so a database is usable before
-- that file has ever been run, and harmless when it has.
CREATE EXTENSION IF NOT EXISTS vector;

-- Trigram similarity — the lexical half of hybrid retrieval, and what lets an
-- ILIKE over chunk text use an index instead of reading the corpus.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Query statistics. RDS preloads the library on postgres16 by default; this
-- makes the view visible inside this database.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
