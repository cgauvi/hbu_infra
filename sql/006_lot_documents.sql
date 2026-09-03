-- requires: rag.chunks
--
-- Lot -> PDF. The last hop of the chain 005_silver_lot_features.sql opens up.
--
-- `silver.lot_features` says which map features cover a lot;
-- `rag.chunks.feature_ids` says which features cite each document. Putting the
-- two together is what turns "lot 1 234 567" into "this zone's grille des
-- usages et des normes", which is the document a highest-and-best-use question
-- is answered out of.
--
-- The `-- requires:` header above is read by scripts/db.py, which skips this
-- file with a note when rag.chunks does not exist yet - that table belongs to
-- the dataplatform and is created on its first load. Same handling as
-- 003_spatial_search.sql; see its header for why skipping beats failing.
--
-- Ordering note: this file sorts after 005, which is what lets it name
-- silver.lot_features in a view body. 003_spatial_search.sql cannot, which is
-- why rag.search_at_lot there still does the lot x feature intersection inline.
-- That function answers from a point and stays the entry point for "what
-- applies here"; this view answers from a lot already identified, off a join
-- that has already been computed.

SET search_path TO rag, public;

-- ---------------------------------------------------------------------------
-- Every document that applies to a lot, most-of-the-lot first
--
-- One row per (lot, document), not per chunk: rag.chunks is denormalised, so
-- the provenance columns repeat across a document's chunks and have to be
-- collapsed before the join or a 40-chunk grid would arrive 40 times.
--
-- `coverage_rank` is 1 for the layer's dominant feature on that lot, and is
-- the column to filter on when a question wants *the* zoning grid rather than
-- all of them - a lot split across two zones legitimately has two, and a lot
-- clipping a neighbour's zone by 8 cm has a second one that is a survey
-- artifact. Ranked per (lot, source_table): the ranking is meaningless across
-- layers, which overlap each other freely.
--
-- It is *not* ranked across snapshots, and does not need to be:
-- `rag.lots.lot_uid` is a surrogate under UNIQUE (lot_number, scrape_date), so
-- one lot_uid is one lot on one date and the window already sits inside a
-- single snapshot. A caller filtering by `lot_number` rather than by lot_uid
-- is the one that spans them, and gets a rank 1 per date - which is why
-- `search_at_lot_number` below resolves the newest snapshot's lot first.
--
-- `overlap_area_m2` is carried alongside `pct_of_lot` because the two answer
-- different questions and only one of them can answer this: how much of a lot
-- a zone *should* govern before it counts is a judgement, and a percentage
-- states it; whether a zone covers the lot at all is not, and below about a
-- square metre the answer is no whatever the parcel's size. That is the
-- cadastre and the zoning layer being drawn by two offices whose lines miss
-- each other by centimetres along every lot line - a survey disagreement
-- wearing a zone's number, not a small amount of governing. The column is on
-- the view rather than the cutoff being applied here, for the reason
-- 005_silver_lot_features.sql gives for not thresholding at all: the cutoff
-- belongs to the question being asked. hbu_dataplatform's
-- `postgis.MIN_ZONE_OVERLAP_M2` and hbu_rag_map's `queries.MIN_ZONE_OVERLAP_M2`
-- are the same square metre applied at the two ends that ask it.
-- ---------------------------------------------------------------------------

-- Dropped rather than replaced, for one reason and only this one: CREATE OR
-- REPLACE VIEW may append columns but may not insert one, and
-- `overlap_area_m2` belongs beside `pct_of_lot` rather than after the document
-- columns. Without CASCADE on purpose - nothing depends on this view today
-- (gold.lot_profiles is a table the pipeline fills, not a dependent), and if
-- something ever does, failing loudly here beats dropping it silently.
DROP VIEW IF EXISTS rag.lot_documents;

CREATE VIEW rag.lot_documents AS
    WITH documents AS (
        SELECT DISTINCT
               doc_id, url, title, source_table, neighborhood,
               scrape_date, feature_ids
          FROM rag.chunks
    )
    SELECT lf.lot_uid,
           l.lot_number,
           lf.neighborhood,
           lf.scrape_date,
           lf.source_table,
           lf.feature_id,
           lf.pct_of_lot,
           lf.overlap_area_m2,
           rank() OVER (
               PARTITION BY lf.lot_uid, lf.source_table
               ORDER BY lf.pct_of_lot DESC
           ) AS coverage_rank,
           d.doc_id,
           d.url,
           d.title
      FROM silver.lot_features lf
      JOIN rag.lots l USING (lot_uid)
      JOIN documents d
        ON d.source_table = lf.source_table
       -- The borough belongs in the join, not just the partition filter: the
       -- slug in `source_table` carries no namespace, so C01-001 exists in
       -- every borough that publishes a VSP_REG_ZONE.
       AND d.neighborhood = lf.neighborhood
       AND d.scrape_date = lf.scrape_date
       AND d.feature_ids ? lf.feature_id;

-- ---------------------------------------------------------------------------
-- Vector search over the documents that apply to one named lot
--
-- The companion to rag.search_at_lot, entered from the other end. That one
-- takes a point, finds the lot under it and intersects features on the fly;
-- this one takes the lot number - which is what a user actually has - and
-- reads the join back out of silver.lot_features instead of recomputing it.
--
-- Two cutoffs, and the defaults differ because they are different in kind.
--
-- `min_pct_of_lot` is the judgement, defaulted to 0 so the answer includes
-- everything unless the caller says otherwise. 1.0 is a reasonable value once
-- the misalignment between cadastre and zoning is the thing being filtered.
--
-- `min_overlap_m2` is the artefact filter, and defaults to 1 because there is
-- no threshold a caller could sensibly read it back at: under a square metre
-- the two publishers' lines have simply missed each other, and the grid that
-- comes back is the block next door's. Pass 0 to get the old behaviour.
-- ---------------------------------------------------------------------------

-- The signature gains an argument, so the old one has to go explicitly:
-- CREATE OR REPLACE FUNCTION matches on the argument list and would leave a
-- second five-argument overload behind, which the ownership block below then
-- names ambiguously.
DROP FUNCTION IF EXISTS rag.search_at_lot_number(
    vector, text, integer, double precision, text
);

CREATE OR REPLACE FUNCTION rag.search_at_lot_number (
    query_embedding vector,
    in_lot_number   text,
    match_count     integer DEFAULT 5,
    min_pct_of_lot  double precision DEFAULT 0,
    min_overlap_m2  double precision DEFAULT 1,
    on_source_table text DEFAULT NULL
)
RETURNS TABLE (
    lot_number   text,
    feature_id   text,
    source_table text,
    pct_of_lot   double precision,
    chunk_id     text,
    doc_id       text,
    url          text,
    title        text,
    chunk_text   text,
    similarity   double precision
)
LANGUAGE sql STABLE
AS $$
    -- A lot number is unique per scrape, not across them, so the newest
    -- scrape carrying it is the current cadastre - the same rule
    -- rag.search_at_lot applies to the lot under a point.
    WITH lot AS (
        SELECT l.lot_uid, l.lot_number
          FROM rag.lots l
         WHERE l.lot_number = in_lot_number
         ORDER BY l.scrape_date DESC
         LIMIT 1
    ),
    applies AS (
        SELECT lf.feature_id, lf.source_table, lf.pct_of_lot,
               lf.neighborhood, lf.scrape_date, lot.lot_number
          FROM lot
          JOIN silver.lot_features lf USING (lot_uid)
         WHERE lf.pct_of_lot >= min_pct_of_lot
           AND lf.overlap_area_m2 >= min_overlap_m2
           AND (on_source_table IS NULL OR lf.source_table = on_source_table)
    )
    SELECT a.lot_number,
           a.feature_id,
           a.source_table,
           a.pct_of_lot,
           c.chunk_id,
           c.doc_id,
           c.url,
           c.title,
           c.text,
           1 - (c.embedding <=> query_embedding) AS similarity
      FROM applies a
      JOIN rag.chunks c
        ON c.source_table = a.source_table
       AND c.neighborhood = a.neighborhood
       AND c.scrape_date = a.scrape_date
       AND c.feature_ids ? a.feature_id
     ORDER BY c.embedding <=> query_embedding
     LIMIT match_count;
$$;

DO $$
DECLARE
    app_role text := 'urban_rag';
    ro_role  text := 'urban_rag_ro';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
        RETURN;
    END IF;

    EXECUTE format('ALTER VIEW rag.lot_documents OWNER TO %I', app_role);
    EXECUTE format(
        'ALTER FUNCTION rag.search_at_lot_number(vector, text, integer,'
        ' double precision, double precision, text) OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON rag.lot_documents TO %I', ro_role);
    END IF;
END
$$;
