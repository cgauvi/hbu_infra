-- The spatial side of the corpus.
--
-- What is deliberately NOT here: rag.chunks. The dataplatform creates and owns
-- that table — denormalised, one row per embedded chunk, `embedding
-- vector(N)`, `feature_ids jsonb` — on its first load, from
-- urban_rag.rag.pgvector. Two repos creating the same table with slightly
-- different DDL is the failure mode this file exists to avoid.
--
-- What is here is what nothing else creates: the geometry the chunks are
-- about. `rag.chunks.feature_ids` already records which map features cite each
-- document, but it holds ids, not shapes — so on its own it can answer "which
-- zones cite this rule" and not "which rules apply at this address".
--
-- Owned by the same role that owns rag.chunks, so a single GRANT covers both.

-- The schema is normally created by the dataplatform's bootstrap, owned by the
-- pipeline's role. Created here too so this file stands alone on a database
-- where the bootstrap has not run yet; the ownership block at the end settles
-- who owns it either way.
CREATE SCHEMA IF NOT EXISTS rag;

SET search_path TO rag, public;

-- ---------------------------------------------------------------------------
-- Features — one row per map feature per scrape
--
-- `attributes` stays jsonb rather than becoming 24 typed tables: the source
-- layers add and retire columns between scrapes, and a schema that needs a
-- migration every time the city edits a layer will not survive the pipeline.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS rag.features (
    feature_uid  bigserial PRIMARY KEY,
    -- Matches the ids the dataplatform writes into rag.chunks.feature_ids.
    feature_id   text NOT NULL,
    source_table text NOT NULL,
    neighborhood text NOT NULL,
    scrape_date  date NOT NULL,
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- EPSG:4326 to match what the scrape reprojects to server-side with
    -- MI_Transform. Geometry type is left open because one table's rows are
    -- polygons and another's are points.
    geom         geometry(Geometry, 4326),
    UNIQUE (source_table, feature_id, scrape_date)
);

CREATE INDEX IF NOT EXISTS features_geom_idx ON rag.features USING gist (geom);
CREATE INDEX IF NOT EXISTS features_attrs_idx ON rag.features USING gin (attributes);
CREATE INDEX IF NOT EXISTS features_partition_idx
    ON rag.features (neighborhood, scrape_date);

-- ---------------------------------------------------------------------------
-- Lots — cadastral parcels from Infolot
--
-- The unit a highest-and-best-use question is actually asked about: not "what
-- does zone C01-001 permit" but "what can I build on lot 1 234 567".
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS rag.lots (
    lot_uid      bigserial PRIMARY KEY,
    lot_number   text NOT NULL,
    neighborhood text NOT NULL,
    scrape_date  date NOT NULL,
    area_m2      double precision,
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
    geom         geometry(MultiPolygon, 4326),
    UNIQUE (lot_number, scrape_date)
);

CREATE INDEX IF NOT EXISTS lots_geom_idx ON rag.lots USING gist (geom);
CREATE INDEX IF NOT EXISTS lots_number_idx ON rag.lots (lot_number);

-- ---------------------------------------------------------------------------
-- Ownership
--
-- These tables are created by the master user, because only it can install
-- PostGIS — but everything in the `rag` schema is meant to be owned by the
-- pipeline's role, which is what the dataplatform's grants are written
-- against. Handing them over here keeps one owner for the whole schema
-- regardless of which of the two bootstrap steps ran first.
--
-- Guarded on the role existing, so this file also works on a database where
-- pgvector_bootstrap.sql has not been run yet.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    app_role text := 'urban_rag';
    ro_role  text := 'urban_rag_ro';
    relation text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
        RAISE NOTICE
            'role % does not exist — run the dataplatform''s pgvector_bootstrap.sql, '
            'then re-run this file to hand over ownership', app_role;
        RETURN;
    END IF;

    EXECUTE format('ALTER SCHEMA rag OWNER TO %I', app_role);

    -- ALTER TABLE ... OWNER TO carries owned sequences with it, so the
    -- bigserial columns need no separate statement.
    FOREACH relation IN ARRAY ARRAY['rag.features', 'rag.lots'] LOOP
        EXECUTE format('ALTER TABLE %s OWNER TO %I', relation, app_role);
    END LOOP;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT USAGE ON SCHEMA rag TO %I', ro_role);
        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA rag TO %I', ro_role);
    END IF;
END
$$;
