-- silver.council_item_sites - where each council planning item is on the
-- ground - and the two columns silver.council_planning_items (030) gains
-- for the same question: `citations`, which points from an item at the
-- passages and the PDF that state it, and `outcome`, the decision collapsed
-- to approved / refused / in_progress.
--
-- ---------------------------------------------------------------------------
-- Why an item needs a site
-- ---------------------------------------------------------------------------
--
-- 030 reads a minute into columns - the zones it is about, the addresses and
-- the lot numbers it names - and stops there: a lot number is text, an
-- address is text, and "which demolitions were decided near 439 rue
-- Jeanne-d'Arc" cannot be asked of text. This table is the join to the
-- ground, computed once by the dataplatform
-- (hbu_dataplatform.cities.quebec_city.council.sites) and kept, one row per
-- (item, site):
--
--   site_kind = 'lot'      a lot number the item names, found in rag.lots.
--                          The cadastre writes `1 303 691` and the parser
--                          strips the spaces, so the match is on the digits.
--                          The lot's polygon.
--   site_kind = 'address'  a civic address the item names, found in
--                          silver.lot_addresses by civic number and the
--                          street name folded the way hbu_rag_map folds what
--                          a person types (silver.street_key below) - so
--                          "chemin Ste-Foy" in a minute reaches "Chemin
--                          Sainte-Foy" in the layer. The parcel the door
--                          stands on, as a polygon, so a distance is to the
--                          lot and not to a point on its facade.
--   site_kind = 'zone'     a zone code the item names, found in rag.features.
--                          The zone's polygon - coarse, and kept apart by
--                          kind for that reason: a zone is within 500 m of
--                          most points inside it, so a "near" question asks
--                          for lots and addresses unless it says otherwise.
--
-- `is_subject` says whether the item is *about* that site (the title's
-- address, "relativement à la zone") or merely names it (the assembly's
-- venue, a neighbouring zone the plan extract labels). `match_basis` says
-- how the match was made: 'lot_number', 'address', 'address_cardinal' (the
-- minute wrote "boulevard René-Lévesque" and the layer prints Est and
-- Ouest; the first door with that number on either was taken), 'zone'.
--
-- A site that matches nothing - a lot not in the loaded cadastre, an
-- address in a city whose points were never loaded, a zone of a borough not
-- scraped - is not written, and the asset counts it. On the borough axis
-- with 030, keyed on the item plus the site.
--
-- ---------------------------------------------------------------------------
-- citations
-- ---------------------------------------------------------------------------
--
-- `citations` is jsonb on the item, filled by the same asset:
--
--   {"url": ..., "doc_id": ...,            the document the item was read from
--    "source_kind": "minutes",
--    "document_number": "GT2025-233",       when it has one
--    "chunk_ids": ["<doc_id>:0003", ...],   the rag.chunks rows covering it
--    "trail": [{"doc_id", "url", "kind", "document_number"}, ...],
--                                           for a minute: what it led to
--    "minutes": [{"doc_id", "url"}, ...]}   for a trail document: the
--                                           minutes that led here
--
-- The chunk ids are the join to the corpus: the council documents are
-- chunked and embedded into rag.chunks under source tables `council_*`
-- (hbu_dataplatform.cities.quebec_city.council.corpus), and an item's
-- passages are the chunks whose span overlaps its agenda item. 033 reads it
-- from the other side, to search the corpus near a point.
--
-- `outcome` is the decision stage folded to what a reader filtering on
-- "approved or rejected" means - adopted and granted are `approved`, refused
-- is `refused`, every stage short of a decision is `in_progress`, nothing
-- stated is null. The council's own opinion stays in `council_opinion`: a
-- conseil de quartier advises, the arrondissement decides.
--
-- No `-- requires:` header: everything named here is created by this repo's
-- own files, which sort before it.

SET search_path TO silver, public;

-- ---------------------------------------------------------------------------
-- 030 gains two columns
-- ---------------------------------------------------------------------------

ALTER TABLE silver.council_planning_items
    ADD COLUMN IF NOT EXISTS citations jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- approved | refused | in_progress
    ADD COLUMN IF NOT EXISTS outcome text;

CREATE INDEX IF NOT EXISTS council_planning_items_outcome_idx
    ON silver.council_planning_items (outcome);
CREATE INDEX IF NOT EXISTS council_planning_items_lots_idx
    ON silver.council_planning_items USING gin (lot_numbers);
-- `citations->'chunk_ids' ? chunk_id` is how 033 finds an item from a chunk.
CREATE INDEX IF NOT EXISTS council_planning_items_chunks_idx
    ON silver.council_planning_items USING gin ((citations -> 'chunk_ids'));

-- ---------------------------------------------------------------------------
-- The two folds, as functions
-- ---------------------------------------------------------------------------
--
-- hbu_rag_map folds a street name in Python (`queries.street_key`) and in
-- SQL it generates (`queries._STREET_KEY_SQL`), and 031 repeats the SQL for
-- the street directory. The sites join needs it on both sides at once - the
-- minute's "chemin Ste-Foy" and the layer's "Chemin Sainte-Foy" - so here it
-- is once, as a function the dataplatform can call. The rule is the same:
-- lower-case, accents to their letters, punctuation to spaces, "st"/"ste" to
-- "saint"/"sainte", ordinals to "Ne" with the first back to "1re". The
-- database has no `unaccent`, hence the translate over the letters French
-- uses.
--
-- `street_core` also drops a leading street type - the generic word a
-- person leaves out and a minute may abbreviate ("boul. René-Lévesque").
-- Numbered streets ("14e Avenue") carry their type last and keep it.

CREATE OR REPLACE FUNCTION silver.street_key(name text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
    SELECT btrim(regexp_replace(regexp_replace(
               regexp_replace(regexp_replace(regexp_replace(regexp_replace(
                   translate(replace(replace(lower(name), 'œ', 'oe'), 'æ', 'ae'),
                             'àâäéèêëîïôöùûüçñ', 'aaaeeeeiioouuucn'),
                   '[-‐–—''’.,/()]', ' ', 'g'),
               '\s+', ' ', 'g'),
               '\mst\M', 'saint', 'g'), '\mste\M', 'sainte', 'g'),
           '\m(\d+)(st|nd|rd|th|e|er|re|ere|eme)\M', '\1e', 'g'),
           '\m1e\M', '1re', 'g'));
$$;

CREATE OR REPLACE FUNCTION silver.street_core(name text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
    SELECT btrim(regexp_replace(
        silver.street_key(name),
        '^(rue|avenue|ave|av|boulevard|boul|blvd|bd|chemin|ch|place|pl|terrasse'
        '|allee|montee|cote|croissant|carre|cours|impasse|promenade|rang|route|rte'
        '|ruelle|square|voie|autoroute|grande allee)(\s+|$)',
        ''));
$$;

-- A place name - a municipality as Adresses Québec prints it - folded the
-- way hbu_rag_map's `places.fold` folds what a person writes, so "Québec"
-- compares equal to "quebec".
CREATE OR REPLACE FUNCTION silver.place_key(name text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $$
    SELECT btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
               translate(replace(replace(lower(name), 'œ', 'oe'), 'æ', 'ae'),
                         'àâäéèêëîïôöùûüçñ', 'aaaeeeeiioouuucn'),
               '[-‐–—''’.,/()]', ' ', 'g'),
           '\s+', ' ', 'g'),
           '\mst\M', 'saint', 'g'), '\mste\M', 'sainte', 'g'));
$$;

-- ---------------------------------------------------------------------------
-- The table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.council_item_sites (
    scrape_date    date NOT NULL,
    neighborhood   text NOT NULL,
    -- The item: silver.council_planning_items' key within the partition.
    doc_id         text NOT NULL,
    item_index     integer NOT NULL,
    -- 'lot' | 'address' | 'zone'
    site_kind      text NOT NULL,
    -- The lot number, address or zone code as the item wrote it.
    site_key       text NOT NULL,
    -- Whether the item is about this site or merely names it.
    is_subject     boolean NOT NULL DEFAULT false,
    -- 'lot_number' | 'address' | 'address_cardinal' | 'zone'
    match_basis    text NOT NULL,
    -- The parcel, for a lot or an address site, as the cadastre spells it.
    lot_number     text,
    lot_uid        bigint,
    -- The zone, for a zone site.
    feature_id     text,
    source_table   text,
    geom           geometry(Geometry, 4326) NOT NULL,
    loaded_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, doc_id, item_index, site_kind, site_key)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS council_item_sites_geom_idx
    ON silver.council_item_sites USING gist (geom);
CREATE INDEX IF NOT EXISTS council_item_sites_item_idx
    ON silver.council_item_sites (neighborhood, scrape_date, doc_id, item_index);
CREATE INDEX IF NOT EXISTS council_item_sites_lot_idx
    ON silver.council_item_sites (lot_number);

-- ---------------------------------------------------------------------------
-- The planning items decided near a point
--
-- The structured half of the question - "which demolitions near here were
-- approved or refused in the last year" is a filter on item_kind, outcome
-- and date over the sites within a radius, and needs no embedding. One row
-- per item, carrying its nearest qualifying site; the current snapshot of
-- each borough. Nearest first, then newest.
--
-- `since`/`until` apply to the decision's own date where the document
-- states one, else to the assembly's: a resolution extract is dated by its
-- sitting, a minute by its meeting.
--
-- `in_site_kinds` defaults to lots and addresses, for the reason the header
-- gives: a zone polygon is near almost everything inside it. Pass
-- ARRAY['lot','address','zone'] to widen to the zone an amendment is about.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rag.council_items_near (
    lon             double precision,
    lat             double precision,
    radius_m        double precision DEFAULT 500,
    in_item_kinds   text[] DEFAULT NULL,
    in_outcomes     text[] DEFAULT NULL,
    since           date DEFAULT NULL,
    until           date DEFAULT NULL,
    in_site_kinds   text[] DEFAULT ARRAY['lot', 'address'],
    in_neighborhood text DEFAULT NULL,
    match_count     integer DEFAULT 20
)
RETURNS TABLE (
    neighborhood        text,
    scrape_date         date,
    doc_id              text,
    item_index          integer,
    source_kind         text,
    item_kind           text,
    title               text,
    council_name        text,
    meeting_date        date,
    decision            text,
    outcome             text,
    decision_date       date,
    item_date           date,
    council_opinion     text,
    council_opinion_excerpt text,
    document_number     text,
    url                 text,
    subject_addresses   jsonb,
    lot_numbers         jsonb,
    subject_zone_codes  jsonb,
    project_dwellings   integer,
    max_dwellings_before integer,
    max_dwellings_after integer,
    citations           jsonb,
    excerpt             text,
    distance_m          double precision,
    site_kind           text,
    site_key            text,
    site_lot_number     text,
    is_subject          boolean
)
LANGUAGE sql STABLE
AS $$
    WITH origin AS (
        SELECT ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography AS g
    ),
    current AS (
        SELECT i.neighborhood, max(i.scrape_date) AS scrape_date
          FROM silver.council_planning_items i
         GROUP BY i.neighborhood
    ),
    nearest AS (
        SELECT DISTINCT ON (s.neighborhood, s.doc_id, s.item_index)
               s.neighborhood, s.scrape_date, s.doc_id, s.item_index,
               ST_Distance(s.geom::geography, o.g) AS distance_m,
               s.site_kind, s.site_key, s.lot_number, s.is_subject
          FROM silver.council_item_sites s
          JOIN current c
            ON c.neighborhood = s.neighborhood
           AND c.scrape_date = s.scrape_date
         CROSS JOIN origin o
         WHERE ST_DWithin(s.geom::geography, o.g, radius_m)
           AND s.site_kind = ANY (in_site_kinds)
           AND (in_neighborhood IS NULL OR s.neighborhood = in_neighborhood)
         -- The subject site before a merely named one at the same distance.
         ORDER BY s.neighborhood, s.doc_id, s.item_index,
                  ST_Distance(s.geom::geography, o.g), s.is_subject DESC
    )
    SELECT i.neighborhood,
           i.scrape_date,
           i.doc_id,
           i.item_index,
           i.source_kind,
           i.item_kind,
           i.title,
           i.council_name,
           i.meeting_date,
           i.decision,
           i.outcome,
           i.decision_date,
           coalesce(i.decision_date, i.meeting_date) AS item_date,
           i.council_opinion,
           i.council_opinion_excerpt,
           i.document_number,
           i.url,
           i.subject_addresses,
           i.lot_numbers,
           i.subject_zone_codes,
           i.project_dwellings,
           i.max_dwellings_before,
           i.max_dwellings_after,
           i.citations,
           i.excerpt,
           n.distance_m,
           n.site_kind,
           n.site_key,
           n.lot_number,
           n.is_subject
      FROM nearest n
      JOIN silver.council_planning_items i
        ON i.neighborhood = n.neighborhood
       AND i.scrape_date = n.scrape_date
       AND i.doc_id = n.doc_id
       AND i.item_index = n.item_index
     WHERE (in_item_kinds IS NULL OR i.item_kind = ANY (in_item_kinds))
       AND (in_outcomes IS NULL OR i.outcome = ANY (in_outcomes))
       AND (since IS NULL OR coalesce(i.decision_date, i.meeting_date) >= since)
       AND (until IS NULL OR coalesce(i.decision_date, i.meeting_date) <= until)
     ORDER BY n.distance_m, coalesce(i.decision_date, i.meeting_date) DESC NULLS LAST,
              i.doc_id, i.item_index
     LIMIT match_count;
$$;

DO $$
DECLARE
    app_role text := 'urban_rag';
    ro_role  text := 'urban_rag_ro';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
        RAISE NOTICE
            'role % does not exist - apply 000_roles.sql, then re-run this '
            'file to hand over ownership', app_role;
        RETURN;
    END IF;

    EXECUTE format('ALTER TABLE silver.council_item_sites OWNER TO %I', app_role);
    EXECUTE format('ALTER FUNCTION silver.street_key(text) OWNER TO %I', app_role);
    EXECUTE format('ALTER FUNCTION silver.street_core(text) OWNER TO %I', app_role);
    EXECUTE format('ALTER FUNCTION silver.place_key(text) OWNER TO %I', app_role);
    EXECUTE format(
        'ALTER FUNCTION rag.council_items_near(double precision, double precision,'
        ' double precision, text[], text[], date, date, text[], text, integer)'
        ' OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON silver.council_item_sites TO %I', ro_role);
    END IF;
END
$$;
