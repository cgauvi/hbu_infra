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

-- ---------------------------------------------------------------------------
-- PostGIS 3.1, for the map
--
-- hbu_rag_map draws its lots, footprints, zones and massing as Mapbox Vector
-- Tiles, which is `ST_AsMVT` plus the five-argument `ST_TileEnvelope` — the
-- one with a `margin`, added in 3.1. Both come with PostGIS itself, so there
-- is nothing to install; what there is, is a version to be on.
--
-- A notice rather than a failure, because everything else in this database
-- works on an older PostGIS and the app has a fallback: it draws GeoJSON by
-- viewport instead, capped, and says in its sidebar that it is doing so. This
-- is here so an operator learns that from `db-init` rather than from a map
-- that goes blank over a whole borough.
--
-- RDS ships 3.4 on postgres16 and the local container is built from
-- postgis/postgis:16-3.4, so this should never fire. It fires on a database
-- restored from an older instance, which is exactly when nobody thinks to look.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    lib     text := postgis_lib_version();
    -- Only the leading digits of each of the first two parts. A development
    -- build reports "3.5.0dev", and a bare ::int[] cast on that would fail
    -- db-init over a version check that exists to print a notice.
    version int[] := (regexp_match(lib, '^(\d+)\.(\d+)'))::int[];
BEGIN
    IF version IS NULL OR version < ARRAY[3, 1] THEN
        RAISE NOTICE
            'PostGIS % is older than 3.1, so ST_AsMVT is unavailable and '
            'hbu_rag_map will fall back to its capped GeoJSON renderer. '
            'Upgrade the instance to draw the map from vector tiles.', lib;
    END IF;
END
$$;
