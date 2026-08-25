-- requires: rag.chunks
--
-- Spatial retrieval: the functions that join geometry to the vector corpus.
--
-- The `-- requires:` header above is read by scripts/db.py, which skips this
-- file with a note when rag.chunks does not exist yet. That table is created
-- by the dataplatform on its first load, so on a fresh database the order is:
--
--     make db-init        # extensions + rag.features + rag.lots  (this repo)
--     <dagster: document_index>   # creates and fills rag.chunks  (dataplatform)
--     make db-init        # now also creates the functions below
--
-- Skipping rather than failing is the point: a SQL-language function body is
-- parsed at CREATE time, so these cannot be created against a table that is
-- not there, and a hard error on the first run of a new database would be
-- noise rather than information.
--
-- Note on the column names below: rag.chunks is the dataplatform's table, so
-- its text column is `text` and its provenance columns (url, source_table,
-- neighborhood, scrape_date) live on the chunk row itself rather than in a
-- separate documents table. These functions read that shape as it is.

SET search_path TO rag, public;

-- ---------------------------------------------------------------------------
-- Which features cite a given chunk's document
--
-- rag.chunks.feature_ids is a jsonb array of the ids the scrape saw pointing
-- at that document. Expanding it into a join is what connects the corpus to
-- geometry, and doing it in a view means the expansion is written once.
--
-- The borough is part of the match, not just of the partition: `source_table`
-- on both sides is the file slug (`Reglement_urbanisme__VSP_REG_ZONE`), which
-- drops the namespace the Spectrum path carries, and zone numbers restart at
-- C01-001 in every borough. Without it a Villeray grid would come back cited
-- by a Rosemont zone of the same number.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW rag.chunk_features AS
    SELECT c.chunk_id,
           c.doc_id,
           f.feature_uid,
           f.geom
      FROM rag.chunks c
      CROSS JOIN LATERAL jsonb_array_elements_text(c.feature_ids) AS fid(value)
      JOIN rag.features f
        ON f.feature_id = fid.value
       AND f.source_table = c.source_table
       AND f.neighborhood = c.neighborhood
       AND f.scrape_date = c.scrape_date;

-- ---------------------------------------------------------------------------
-- Vector search narrowed to a place
--
-- ST_DWithin over geography casts the radius to metres and still uses the GiST
-- index, so the candidate set is "chunks whose document is cited by a feature
-- near this point" and only those get ranked by similarity.
--
-- One consequence worth knowing: because the spatial filter runs first and is
-- selective, the planner will usually scan the surviving chunks rather than
-- use the HNSW index — which is the right plan, and means recall here is
-- exact rather than approximate.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rag.search_near (
    query_embedding vector,
    lon             double precision,
    lat             double precision,
    radius_m        double precision DEFAULT 500,
    match_count     integer DEFAULT 5,
    on_scrape_date  date DEFAULT NULL
)
RETURNS TABLE (
    chunk_id     text,
    doc_id       text,
    url          text,
    title        text,
    source_table text,
    neighborhood text,
    scrape_date  date,
    chunk_text   text,
    distance_m   double precision,
    similarity   double precision
)
LANGUAGE sql STABLE
AS $$
    WITH origin AS (
        SELECT ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography AS g
    ),
    nearby AS (
        SELECT cf.chunk_id,
               min(ST_Distance(cf.geom::geography, origin.g)) AS distance_m
          FROM rag.chunk_features cf
         CROSS JOIN origin
         WHERE ST_DWithin(cf.geom::geography, origin.g, radius_m)
         GROUP BY cf.chunk_id
    )
    SELECT c.chunk_id,
           c.doc_id,
           c.url,
           c.title,
           c.source_table,
           c.neighborhood,
           c.scrape_date,
           c.text,
           n.distance_m,
           1 - (c.embedding <=> query_embedding) AS similarity
      FROM nearby n
      JOIN rag.chunks c USING (chunk_id)
     WHERE on_scrape_date IS NULL OR c.scrape_date = on_scrape_date
     ORDER BY c.embedding <=> query_embedding
     LIMIT match_count;
$$;

-- ---------------------------------------------------------------------------
-- Everything the corpus says about the lot a point falls in
--
-- Containment rather than proximity, so there is no radius to pick and no
-- neighbouring zone bleeding into the answer. This is the query a
-- highest-and-best-use question reduces to.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rag.search_at_lot (
    query_embedding vector,
    lon             double precision,
    lat             double precision,
    match_count     integer DEFAULT 5
)
RETURNS TABLE (
    lot_number   text,
    chunk_id     text,
    url          text,
    source_table text,
    chunk_text   text,
    similarity   double precision
)
LANGUAGE sql STABLE
AS $$
    WITH point AS (
        SELECT ST_SetSRID(ST_MakePoint(lon, lat), 4326) AS g
    ),
    -- The most recent scrape that has this lot; a cadastre changes rarely, but
    -- when it does the current shape is the one that matters.
    lot AS (
        SELECT l.lot_number, l.geom
          FROM rag.lots l, point p
         WHERE ST_Intersects(l.geom, p.g)
         ORDER BY l.scrape_date DESC
         LIMIT 1
    )
    SELECT lot.lot_number,
           c.chunk_id,
           c.url,
           c.source_table,
           c.text,
           1 - (c.embedding <=> query_embedding) AS similarity
      FROM lot
      JOIN rag.features f ON ST_Intersects(f.geom, lot.geom)
      JOIN rag.chunks c
        ON c.source_table = f.source_table
       AND c.neighborhood = f.neighborhood
       AND c.scrape_date = f.scrape_date
       AND c.feature_ids ? f.feature_id
     ORDER BY c.embedding <=> query_embedding
     LIMIT match_count;
$$;

-- What is loaded, at a glance — the spatial companion to rag.chunks_meta.
CREATE OR REPLACE VIEW rag.corpus_status AS
    SELECT c.neighborhood,
           c.scrape_date,
           count(DISTINCT c.doc_id)   AS documents,
           count(*)                   AS chunks,
           count(DISTINCT c.model)    AS models,
           (SELECT count(*) FROM rag.features f
             WHERE f.neighborhood = c.neighborhood
               AND f.scrape_date = c.scrape_date) AS features,
           (SELECT count(*) FROM rag.features f
             WHERE f.neighborhood = c.neighborhood
               AND f.scrape_date = c.scrape_date
               AND f.geom IS NOT NULL)            AS features_with_geometry
      FROM rag.chunks c
     GROUP BY c.neighborhood, c.scrape_date
     ORDER BY c.scrape_date DESC, c.neighborhood;

-- Same handover as 002_spatial.sql: created by the master user because it runs
-- in the same session, owned by the role that owns everything else in `rag`.
DO $$
DECLARE
    app_role text := 'urban_rag';
    ro_role  text := 'urban_rag_ro';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
        RETURN;
    END IF;

    EXECUTE format('ALTER VIEW rag.chunk_features OWNER TO %I', app_role);
    EXECUTE format('ALTER VIEW rag.corpus_status OWNER TO %I', app_role);
    EXECUTE format(
        'ALTER FUNCTION rag.search_near(vector, double precision, double precision,'
        ' double precision, integer, date) OWNER TO %I', app_role);
    EXECUTE format(
        'ALTER FUNCTION rag.search_at_lot(vector, double precision, double precision,'
        ' integer) OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON rag.chunk_features, rag.corpus_status TO %I', ro_role);
    END IF;
END
$$;
