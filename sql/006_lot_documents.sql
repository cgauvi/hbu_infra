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
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW rag.lot_documents AS
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
-- `min_pct_of_lot` is the sliver cutoff, defaulted to 0 so the answer includes
-- everything unless the caller says otherwise. 1.0 is a reasonable value once
-- the misalignment between cadastre and zoning is the thing being filtered.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rag.search_at_lot_number (
    query_embedding vector,
    in_lot_number   text,
    match_count     integer DEFAULT 5,
    min_pct_of_lot  double precision DEFAULT 0,
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
        ' double precision, text) OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON rag.lot_documents TO %I', ro_role);
    END IF;
END
$$;
