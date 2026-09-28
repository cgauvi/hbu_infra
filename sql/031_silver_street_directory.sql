-- silver.street_directory — every loaded street, once, with a search key the
-- map's address box can match a half-typed, misspelt or unaccented street
-- against in one indexed read.
--
-- requires: 001_extensions.sql (pg_trgm), 026_silver_lot_addresses.sql
--
-- ---------------------------------------------------------------------------
-- Why a materialized view
-- ---------------------------------------------------------------------------
--
-- silver.lot_addresses is one row per address *point* — 346,409 of them for
-- four boroughs on 2026-09-26 — and the question a search box asks is about
-- *streets*: which of the 3,554 loaded ones is the person typing. Folding
-- every point's street name and grouping it per keystroke costs 2–3 s on
-- hbu-dev (the sort spills to disk), which is the difference between a box
-- that proposes as you type and one that does not. Grouped once here, the
-- same question is a few thousand rows and answers in milliseconds.
--
-- The view holds, per (neighborhood, municipality, street_name) at the
-- borough's newest snapshot:
--
--   * the counts a proposal states — address rows, lots, doors, the span of
--     civic numbers — so the box can say "Avenue Cardinal-Rouleau, 43 doors,
--     801–999" without a second read;
--   * `extent`, the bounding box of the street's points, so a street in the
--     map's viewport ranks first and "show the street" can frame it;
--   * `street_key`, the street name folded exactly as hbu_rag_map's
--     `queries.street_key` folds what the person typed — lower-cased,
--     unaccented by `translate` (the database has no `unaccent`), hyphens,
--     apostrophes and dots to spaces, `st`/`ste` to `saint`/`sainte`, `1er`
--     to `1re` and every other ordinal to `Ne`. The type word ("avenue") is
--     kept here; the reader strips it from both sides when it compares;
--   * `search_vector`, `to_tsvector('simple', street_key)`: the key as words,
--     for a prefix tsquery (`cardinal:* & roule:*`) that finds the street
--     from its first letters. The `simple` configuration on purpose: street
--     names are proper nouns and a French stemmer would fold "Rouleau" and
--     "Roule" differently from how a person types them;
--   * `loaded_at`, the newest `loaded_at` among the street's points, which is
--     how a reader tells the view has fallen behind the table.
--
-- pg_trgm does the rest at read time: `word_similarity(typed, street_key)`
-- finds "cardnal rouleau" in "avenue cardinal rouleau" (0.74) where a tsquery
-- cannot, and the GIN trigram index below is what keeps that a lookup rather
-- than a scan once the province is loaded.
--
-- ---------------------------------------------------------------------------
-- Keeping it current
-- ---------------------------------------------------------------------------
--
-- A materialized view is a snapshot, so a borough's addresses landing after
-- it was built are not in it until it is refreshed. Two things refresh it:
--
--   * hbu_rag_map's `queries.refresh_street_directory` compares the table's
--     max(loaded_at) with the view's and runs `REFRESH MATERIALIZED VIEW
--     CONCURRENTLY` when the table is newer — once per process every five
--     minutes at most, so the first search after a load pays the ~3 s and
--     nobody else does. CONCURRENTLY needs the unique index below and a
--     populated view, which is why this is `WITH DATA` even on a database
--     whose lot_addresses is still empty (the refresh fills it).
--   * an operator can run the same REFRESH after `make addresses` in the
--     dataplatform, which is what to do when the map's 20 s statement
--     timeout is too short for the aggregate — it is not yet, at 3 s.
--
-- The fold expression here is a third copy of `queries._STREET_KEY_SQL` (the
-- second is `queries.street_key`, in Python). hbu_rag_map's integration test
-- `test_python_and_sql_fold_every_loaded_street_the_same_way` compares all
-- three over every loaded street; change one and it says which.
--
-- Dropping or re-creating silver.lot_addresses needs this view dropped first
-- (`DROP MATERIALIZED VIEW silver.street_directory`), the way any dependent
-- view does. It costs nothing to rebuild.

CREATE MATERIALIZED VIEW IF NOT EXISTS silver.street_directory AS
WITH newest AS (
    -- One snapshot per borough, the newest, as every reader of lot_addresses
    -- picks it; two snapshots would answer the same street twice.
    SELECT neighborhood, max(scrape_date) AS scrape_date
      FROM silver.lot_addresses
     GROUP BY neighborhood
),
a AS (
    SELECT p.neighborhood, p.municipality, p.street_name, p.scrape_date,
           count(*)::int                        AS num_addresses,
           count(DISTINCT p.lot_number)::int    AS num_lots,
           count(DISTINCT p.civic_address)::int AS num_civic_addresses,
           min(p.civic_number)                  AS civic_min,
           max(p.civic_number)                  AS civic_max,
           -- ST_Extent is a box2d and forgets its SRID; put it back so the
           -- reader's ST_MakeEnvelope(..., 4326) can meet it.
           ST_SetSRID(ST_Extent(p.geom)::geometry, 4326) AS extent,
           max(p.loaded_at)                     AS loaded_at
      FROM silver.lot_addresses p
      JOIN newest n ON n.neighborhood = p.neighborhood
                   AND n.scrape_date  = p.scrape_date
     WHERE p.street_name IS NOT NULL
     GROUP BY p.neighborhood, p.municipality, p.street_name, p.scrape_date
)
SELECT a.neighborhood, a.municipality, a.street_name, a.scrape_date,
       a.num_addresses, a.num_lots, a.num_civic_addresses,
       a.civic_min, a.civic_max, a.extent, a.loaded_at,
       -- `queries._STREET_KEY_SQL`, verbatim.
       btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           regexp_replace(regexp_replace(
               translate(replace(replace(lower(a.street_name), 'œ', 'oe'), 'æ', 'ae'),
                         'àâäéèêëîïôöùûüçñ', 'aaaeeeeiioouuucn'),
               '[-''’.]', ' ', 'g'), '\s+', ' ', 'g'),
           '\mst\M', 'saint', 'g'), '\mste\M', 'sainte', 'g'),
           '\m(\d+)(st|nd|rd|th|e|er|re|ere|eme)\M', '\1e', 'g'),
           '\m1e\M', '1re', 'g'))                          AS street_key,
       to_tsvector('simple',
           btrim(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
               regexp_replace(regexp_replace(
                   translate(replace(replace(lower(a.street_name), 'œ', 'oe'), 'æ', 'ae'),
                             'àâäéèêëîïôöùûüçñ', 'aaaeeeeiioouuucn'),
                   '[-''’.]', ' ', 'g'), '\s+', ' ', 'g'),
               '\mst\M', 'saint', 'g'), '\mste\M', 'sainte', 'g'),
               '\m(\d+)(st|nd|rd|th|e|er|re|ere|eme)\M', '\1e', 'g'),
               '\m1e\M', '1re', 'g')))                     AS search_vector
  FROM a
WITH DATA;

-- REFRESH ... CONCURRENTLY wants one unique index over plain columns that
-- covers every row. `municipality` is null on a point the publisher printed
-- none for, and PostgreSQL 15+ can count those nulls as equal.
CREATE UNIQUE INDEX IF NOT EXISTS street_directory_street_idx
    ON silver.street_directory (neighborhood, municipality, street_name)
    NULLS NOT DISTINCT;
-- The prefix tsquery.
CREATE INDEX IF NOT EXISTS street_directory_search_idx
    ON silver.street_directory USING gin (search_vector);
-- word_similarity, for the misspelt street.
CREATE INDEX IF NOT EXISTS street_directory_trgm_idx
    ON silver.street_directory USING gin (street_key gin_trgm_ops);
-- "Which streets are in view" — a boost in the ranking, not a filter.
CREATE INDEX IF NOT EXISTS street_directory_extent_idx
    ON silver.street_directory USING gist (extent);

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
    -- The app refreshes the view, and only its owner may.
    EXECUTE format('ALTER MATERIALIZED VIEW silver.street_directory OWNER TO %I', app_role);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON silver.street_directory TO %I', ro_role);
    END IF;
END
$$;
