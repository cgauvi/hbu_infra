-- requires: rag.chunks
--
-- rag.search_council_chunks - vector search over the council corpus, narrowed
-- by place, date, kind and outcome through the planning items.
--
-- The council documents - the procès-verbaux of Quebec City's conseils de
-- quartier and the fiches, sommaires, resolutions and consultation reports
-- they trail to - are chunked and embedded into rag.chunks beside the zoning
-- grids, under source tables that start with `council_`
-- (hbu_dataplatform.cities.quebec_city.council.corpus). What rag.search_near
-- does for a grid - find the chunks whose *zone* is near a point - this does
-- for a minute, by a different bridge: no map feature cites a minute, but
-- every planning item read out of one carries `citations.chunk_ids` (032),
-- the chunks that cover its agenda item, and silver.council_item_sites puts
-- the item on the ground.
--
-- So the candidate set is: council chunks cited by an item that has a site
-- within `radius_m` of the point, and that passes the kind, outcome and date
-- filters. With no filter at all it is every council chunk, which is the
-- "what did the councils say about X" question with no place attached.
--
-- Each hit carries the nearest qualifying item it is cited by - its index,
-- kind, outcome and date - so a caller can say which decision a passage
-- belongs to without a second query. A chunk cited by two items (the overlap
-- between two agenda items shares a chunk) is reported once, under the
-- nearer one.
--
-- Skipped by db.py until rag.chunks exists, like 003 and 006: a SQL function
-- body is parsed at CREATE time.

SET search_path TO rag, public;

CREATE OR REPLACE FUNCTION rag.search_council_chunks (
    query_embedding vector,
    match_count     integer DEFAULT 10,
    in_neighborhood text DEFAULT NULL,
    lon             double precision DEFAULT NULL,
    lat             double precision DEFAULT NULL,
    radius_m        double precision DEFAULT 500,
    since           date DEFAULT NULL,
    until           date DEFAULT NULL,
    in_item_kinds   text[] DEFAULT NULL,
    in_outcomes     text[] DEFAULT NULL,
    in_site_kinds   text[] DEFAULT ARRAY['lot', 'address']
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
    similarity   double precision,
    distance_m   double precision,
    item_index   integer,
    item_kind    text,
    outcome      text,
    item_date    date
)
LANGUAGE sql STABLE
AS $$
    WITH origin AS (
        SELECT CASE
                   WHEN lon IS NULL OR lat IS NULL THEN NULL::geography
                   ELSE ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography
               END AS g
    ),
    current AS (
        SELECT i.neighborhood, max(i.scrape_date) AS scrape_date
          FROM silver.council_planning_items i
         GROUP BY i.neighborhood
    ),
    -- The items that pass every filter, with their distance to the point
    -- when one was given: NULL distance then means "no site in range" and
    -- the item is dropped below.
    items AS (
        SELECT i.neighborhood, i.doc_id, i.item_index, i.item_kind, i.outcome,
               coalesce(i.decision_date, i.meeting_date) AS item_date,
               i.citations,
               CASE
                   WHEN o.g IS NULL THEN NULL
                   ELSE (
                       SELECT min(ST_Distance(s.geom::geography, o.g))
                         FROM silver.council_item_sites s
                        WHERE s.neighborhood = i.neighborhood
                          AND s.scrape_date = i.scrape_date
                          AND s.doc_id = i.doc_id
                          AND s.item_index = i.item_index
                          AND s.site_kind = ANY (in_site_kinds)
                          AND ST_DWithin(s.geom::geography, o.g, radius_m)
                   )
               END AS distance_m
          FROM silver.council_planning_items i
          JOIN current c
            ON c.neighborhood = i.neighborhood
           AND c.scrape_date = i.scrape_date
         CROSS JOIN origin o
         WHERE (in_neighborhood IS NULL OR i.neighborhood = in_neighborhood)
           AND (in_item_kinds IS NULL OR i.item_kind = ANY (in_item_kinds))
           AND (in_outcomes IS NULL OR i.outcome = ANY (in_outcomes))
           AND (since IS NULL OR coalesce(i.decision_date, i.meeting_date) >= since)
           AND (until IS NULL OR coalesce(i.decision_date, i.meeting_date) <= until)
    ),
    cited AS (
        SELECT DISTINCT ON (it.neighborhood, ids.value)
               it.neighborhood,
               ids.value AS chunk_id,
               it.distance_m,
               it.item_index,
               it.item_kind,
               it.outcome,
               it.item_date
          FROM items it
         CROSS JOIN LATERAL jsonb_array_elements_text(
                   coalesce(it.citations -> 'chunk_ids', '[]'::jsonb)) AS ids(value)
         WHERE lon IS NULL OR lat IS NULL OR it.distance_m IS NOT NULL
         ORDER BY it.neighborhood, ids.value,
                  it.distance_m NULLS LAST, it.item_date DESC NULLS LAST
    ),
    narrowed AS (
        SELECT (lon IS NOT NULL AND lat IS NOT NULL)
            OR since IS NOT NULL OR until IS NOT NULL
            OR in_item_kinds IS NOT NULL OR in_outcomes IS NOT NULL AS yes
    )
    SELECT c.chunk_id,
           c.doc_id,
           c.url,
           c.title,
           c.source_table,
           c.neighborhood,
           c.scrape_date,
           c.text,
           1 - (c.embedding <=> query_embedding) AS similarity,
           k.distance_m,
           k.item_index,
           k.item_kind,
           k.outcome,
           k.item_date
      FROM rag.chunks c
      LEFT JOIN cited k
        ON k.chunk_id = c.chunk_id
       AND k.neighborhood = c.neighborhood
     CROSS JOIN narrowed n
     WHERE c.source_table LIKE 'council\_%'
       AND (in_neighborhood IS NULL OR c.neighborhood = in_neighborhood)
       AND (NOT n.yes OR k.chunk_id IS NOT NULL)
     ORDER BY c.embedding <=> query_embedding
     LIMIT match_count;
$$;

DO $$
DECLARE
    app_role text := 'urban_rag';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
        RETURN;
    END IF;
    EXECUTE format(
        'ALTER FUNCTION rag.search_council_chunks(vector, integer, text,'
        ' double precision, double precision, double precision, date, date,'
        ' text[], text[], text[]) OWNER TO %I', app_role);
END
$$;
