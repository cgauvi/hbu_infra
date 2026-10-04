-- requires: gold.lot_redevelopment_gap
--
-- gold.lot_dossier — one flat row per development site.
--
-- Everything the chat assistant needs to answer a question that spans more
-- than one surface: what the ground is, what stands on it, what the roll says
-- it is worth, what the grid permits, what the solver would build, and what
-- the difference is worth. Six tables pre-joined once, here, rather than
-- re-derived by every caller that wants two of them at the same time.
--
-- WHY THIS EXISTS
--
-- The agent's tools each read one surface and render it as prose, which is
-- right for "what can I build on this lot" and useless for "which lots are
-- zoned for four storeys, assessed under $500k and not heritage-listed".
-- That second question is one SELECT over this view and about six tool calls
-- without it - more than the model gets through before its retry budget is
-- spent. The flat row is what makes the hard question the cheap one.
--
-- THE GRAIN IS THE LOT x ZONE PIECE, NOT THE LOT
--
-- A zoning boundary crossing a parcel makes it two development sites with
-- their own envelopes, frontages and programmes. Every per-piece table below
-- is keyed on (lot_uid, feature_id) for that reason, and so is this view.
--
--   * one row per lot            -> add `WHERE is_primary_zone`
--   * split parcels              -> `WHERE num_lot_zones > 1`
--   * never SUM(lot_area_m2)     -> it is the whole parcel, repeated per
--                                   piece. `piece_area_m2` is the site's.
--
-- Columns that are a *parcel* fact repeated across its pieces carry a
-- `parcel_` prefix, so a SUM over them is visibly wrong rather than quietly
-- wrong.
--
-- JOIN RULES, AND THE TWO TRAPS THEY AVOID
--
-- 1. `lot_uid` is a bigserial reminted on every cadastre reload. It is a
--    valid key *within* one scrape_date - which is how gold is written, all
--    of it off one load - and meaningless across two. This view never joins
--    out to rag.lots, and every join below pins scrape_date, so the uid is
--    safe here. Anything reaching in from outside should come by lot_number.
--
-- 2. The per-piece tables join on the PAIR (lot_uid, feature_id). On lot_uid
--    alone a split parcel multiplies: two pieces x two pieces is four rows,
--    each of them wrong.
--
-- `lot_number` is nullable on the per-piece tables - a piece the cadastre
-- cannot put back to a surface has none - and such a row is filtered out
-- here. A row the assistant cannot name is a row it will invent a name for.
--
-- WHAT IS DELIBERATELY ABSENT
--
-- No geometry. The readers of this view are the agent's tools, which answer
-- in numbers and hand the map a lot number to draw; keeping PostGIS out is
-- also what lets those tools run with `search_path = ''`, which is one of the
-- guards standing between a generated query and this database.
--
-- No ORDER BY, no DISTINCT ON, no window function, no GROUP BY at the top
-- level. Each is an optimisation barrier that would stop a caller's WHERE
-- reaching the base tables, which is the difference between an index scan of
-- one borough and a sequential scan of four. The two sub-selects aggregate a
-- few thousand rows each and hash-join; that is fine.
--
-- PERFORMANCE: THIS IS A MATERIALIZED VIEW, AND WHY
--
-- It began as a plain view, on the reasoning that every caller filters on
-- (neighborhood, scrape_date) and every table underneath indexes that pair,
-- so the predicates would reach the base scans and the six joins would hash.
-- Measured on all four boroughs, that held for three of them and collapsed on
-- the fourth:
--
--   VSMPE  0.4 s    SSC  0.5 s    SAG  5.1 s    CIL  15.2 s
--
-- The CIL plan is the instructive one. The gold-to-gold hash join on
-- (cell_partition, lot_uid, feature_id) estimates ONE row and returns 10 735:
-- the planner multiplies the three equalities' selectivities as if they were
-- independent, and lot_uid alone is nearly unique, so the product clamps to 1.
-- Everything above that estimate then looks cheap as a nested loop, and the
-- heritage join becomes one - against 24 766 Patrimoine rows, rescanned per
-- outer row, 56 135 351 rows removed by the join filter. CIL is the borough
-- this bites because it has eight times the heritage rows of any other, and
-- SAG, with none at all, escapes it despite being three times the size.
--
-- No statistics fix this. CREATE STATISTICS improves single-relation
-- estimates; join selectivity still comes from per-column ndistinct. Fencing
-- the two aggregates into MATERIALIZED CTEs was tried and is worse - 30 s on
-- CIL, 7 s on VSMPE - because the fence also stops the borough predicate
-- reaching them.
--
-- So the join runs once, not per question:
--
--   build, all four boroughs, 168 631 rows   12 s, 66 MB
--   the same borough-wide read, afterwards   36-65 ms   (CIL: 15 157 -> 36)
--
-- REFRESHING IT
--
-- `make db-init` rebuilds it, which is also what populates it on a fresh
-- database. After a gold chain run it is stale until refreshed, and the
-- unique index below is there so that refresh can be CONCURRENTLY - without
-- it, a 12 s ACCESS EXCLUSIVE lock would block every reader the map has:
--
--   REFRESH MATERIALIZED VIEW CONCURRENTLY gold.lot_dossier;
--
-- The unique key is (cell_partition, scrape_date, neighborhood, lot_number,
-- feature_id) - the piece grain plus the partition columns. It is verified
-- unique over the loaded boroughs rather than guaranteed by construction, and
-- the index is what keeps it that way: should a future load break it, the
-- refresh fails loudly instead of quietly doubling the row a tool reports.
SET search_path TO gold, public;

-- No CREATE OR REPLACE for a materialized view, so shipping a new definition
-- means replacing it. Nothing in the database depends on it - the readers are
-- the app and the agent tools, over a connection - so the drop cascades to
-- nothing, and the rebuild below is what populates it on a fresh database.
--
-- DROP MATERIALIZED VIEW refuses a plain view and vice versa, and every
-- database that saw an earlier version of this file still holds the plain one
-- this started as. So the kind is read before it is dropped, which also makes
-- the file safe to re-run against either.
DO $drop$
DECLARE
    kind "char";
BEGIN
    SELECT c.relkind INTO kind
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'gold' AND c.relname = 'lot_dossier';
    IF kind = 'm' THEN
        DROP MATERIALIZED VIEW gold.lot_dossier;
    ELSIF kind = 'v' THEN
        DROP VIEW gold.lot_dossier;
    END IF;
END
$drop$;

CREATE MATERIALIZED VIEW gold.lot_dossier AS

SELECT
    -- identity and grain -----------------------------------------------
    g.scrape_date,
    g.neighborhood,
    g.cell_partition,
    g.lot_number,
    -- Lot numbers are printed with spaces ("2 170 935") and typed without
    -- them at least as often. Carried folded so a caller can match either
    -- without teaching every call site the same regexp.
    regexp_replace(g.lot_number, '\D', '', 'g') AS lot_number_digits,
    g.feature_id,
    h.grid_zone,
    g.is_primary_zone,
    g.num_lot_zones,

    -- the ground -------------------------------------------------------
    g.lot_area_m2                      AS parcel_area_m2,
    g.piece_area_m2,
    100.0 * g.area_share               AS piece_pct_of_parcel,
    g.primary_frontage_m,
    h.buildable_area_m2,
    lp.num_buildings                   AS parcel_num_buildings,
    lp.built_pct_of_lot                AS parcel_built_pct,

    -- what stands today, off the assessment roll ------------------------
    g.existing_floor_area_m2,
    g.existing_num_dwellings,
    g.existing_num_storeys,
    g.existing_year_built,
    g.existing_num_assessment_units,
    g.existing_dominant_use_code,
    g.existing_dominant_use_description,

    -- what it is worth today --------------------------------------------
    g.existing_total_assessed_value    AS piece_assessed_value_cad,
    lp.total_assessed_value            AS parcel_assessed_value_cad,
    lp.roll_year                       AS parcel_roll_year,
    cmp.estimated_value_cad            AS parcel_estimated_value_cad,
    cmp.cap_rate_pct                   AS parcel_cap_rate_pct,
    cmp.assessed_to_estimated_ratio    AS parcel_assessed_to_estimated_ratio,

    -- what the zone permits ----------------------------------------------
    h.permits_residential,
    h.permits_commercial,
    h.permits_industrial,
    -- NULL here means the parsed grid does not cover this zone, which is not
    -- the same as a zone that permits nothing. `grid_parsed` is what lets a
    -- reader tell the two apart; see the flags block below.
    gc.grid_floors_min,
    gc.grid_floors_max,
    gc.grid_height_max_m,
    gc.grid_site_coverage_max_pct,
    gc.grid_density_max,
    gc.grid_usage_summary,
    gc.grid_url,

    -- what could stand -----------------------------------------------------
    g.hbu_status,
    h.hbu_dominant_use,
    h.floors                           AS hbu_floors,
    h.height_m                         AS hbu_height_m,
    h.footprint_m2                     AS hbu_footprint_m2,
    g.hbu_floor_area_m2,
    g.hbu_num_dwellings,
    h.total_capital_cost_cad           AS hbu_total_capital_cost_cad,

    -- the difference, and what it is worth ---------------------------------
    g.is_underbuilt,
    g.floor_area_gap_m2,
    g.dwelling_gap,
    o.storey_headroom,
    g.hbu_npv_cad,
    g.existing_present_value_cad,
    g.redevelopment_npv_gain_cad,
    g.best_future,

    -- the thesis, and what would block it ----------------------------------
    o.investment_thesis,
    o.site_thesis,
    o.site_thesis_rank,
    o.site_irr_pct,
    o.is_good_candidate,
    o.is_heritage_sector,
    o.has_piia_review,
    o.demolition_review_required,
    (her.lot_number IS NOT NULL)       AS parcel_has_heritage,
    her.heritage_layers                AS parcel_heritage_layers,

    -- flags a reader must not recompute -------------------------------------
    --
    -- These three are the difference between an answer and a confident wrong
    -- answer, so they are columns rather than something each caller derives.
    --
    -- The roll assesses a unit here and states no floor area for it. That is
    -- NOT zero floor area, and reporting it as "0% used" or "under-built" is
    -- the one failure mode of this data a reader cannot catch: a plausible
    -- number about a lot with a building on it.
    (g.existing_num_assessment_units > 0
        AND g.existing_floor_area_m2 IS NULL)   AS floor_area_unreported,
    -- The other half: the roll reached no unit at all. Vacant ground, a lane,
    -- a park - here the floor area genuinely is nothing.
    (COALESCE(g.existing_num_assessment_units, 0) <= 0) AS nothing_assessed,
    -- The programme only exists with its parking requirement waived: it
    -- stands on a variance, which has to be said before the storey count is.
    COALESCE(h.parking_waived, false)           AS hbu_parking_waived,
    -- Whether the parsed grid covers this zone at all.
    (gc.feature_id IS NOT NULL)                 AS grid_parsed

FROM gold.lot_redevelopment_gap g

-- gold to gold, on the pair, within the one scrape_date they were written in.
LEFT JOIN gold.lot_highest_best_use h
       ON h.scrape_date    = g.scrape_date
      AND h.cell_partition = g.cell_partition
      AND h.neighborhood   = g.neighborhood
      AND h.lot_uid        = g.lot_uid
      AND h.feature_id     = g.feature_id

LEFT JOIN gold.lot_investment_opportunities o
       ON o.scrape_date    = g.scrape_date
      AND o.cell_partition = g.cell_partition
      AND o.neighborhood   = g.neighborhood
      AND o.lot_uid        = g.lot_uid
      AND o.feature_id     = g.feature_id

-- Parcel-grain tables, keyed on lot_number. Their values repeat across the
-- pieces of a split parcel, which is what the `parcel_` prefix warns about.
LEFT JOIN gold.lot_profiles lp
       ON lp.scrape_date    = g.scrape_date
      AND lp.cell_partition = g.cell_partition
      AND lp.neighborhood   = g.neighborhood
      AND lp.lot_number     = g.lot_number

LEFT JOIN silver.lot_assessment_comparables cmp
       ON cmp.scrape_date    = g.scrape_date
      AND cmp.cell_partition = g.cell_partition
      AND cmp.neighborhood   = g.neighborhood
      AND cmp.lot_number     = g.lot_number

-- Heritage is not a table: it is a set of source_table values in
-- silver.lot_features. Aggregated to one row per parcel so the join cannot
-- multiply the dossier, and listed by layer so a reader can tell a classified
-- immovable from a lot that merely sits inside a protection area.
LEFT JOIN (
    SELECT lf.scrape_date,
           lf.neighborhood,
           lf.lot_number,
           string_agg(DISTINCT lf.source_table, ', ') AS heritage_layers
      FROM silver.lot_features lf
     WHERE lf.source_table LIKE 'Patrimoine\_\_%'
        OR lf.source_table LIKE '%\_REG\_BATIMENT\_PATRIMONIAL'
        OR lf.source_table LIKE '%\_REG\_SECTEUR\_PATRIMONAL'
        OR lf.source_table LIKE '%\_REG\_BATIMENT\_INTERET\_LOCAL'
     GROUP BY lf.scrape_date, lf.neighborhood, lf.lot_number
) her ON her.scrape_date  = g.scrape_date
     AND her.neighborhood = g.neighborhood
     AND her.lot_number   = g.lot_number

-- The parsed grid is one row per *column* of a grille des specifications - a
-- zone states several, and which one governs depends on the lot's frontage.
-- Joined raw it would multiply the dossier, so it is reduced to the envelope
-- the zone permits across its columns: the loosest ceiling and the tightest
-- floor, which is what "what does this zone allow" means without a lot in
-- hand. `zoning_for_lot` remains the tool for the governing column itself.
LEFT JOIN (
    SELECT z.scrape_date,
           z.neighborhood,
           z.feature_id,
           min(z.floors_min)            AS grid_floors_min,
           max(z.floors_max)            AS grid_floors_max,
           max(z.height_max_m)          AS grid_height_max_m,
           max(z.site_coverage_max_pct) AS grid_site_coverage_max_pct,
           max(z.density_max)           AS grid_density_max,
           max(z.url)                   AS grid_url,
           nullif(concat_ws(' | ',
               nullif(string_agg(DISTINCT z.usage_habitation,  ', '), ''),
               nullif(string_agg(DISTINCT z.usage_commerce,    ', '), ''),
               nullif(string_agg(DISTINCT z.usage_industrie,   ', '), ''),
               nullif(string_agg(DISTINCT z.usage_equipements, ', '), '')
           ), '')                       AS grid_usage_summary
      FROM silver.zoning_grid_columns z
     GROUP BY z.scrape_date, z.neighborhood, z.feature_id
) gc ON gc.scrape_date  = g.scrape_date
    AND gc.neighborhood = g.neighborhood
    AND gc.feature_id   = g.feature_id

WHERE g.lot_number IS NOT NULL;


-- The pair every caller filters on. A borough-wide read is an index scan of
-- this and a sort of what comes back.
CREATE INDEX lot_dossier_neighborhood_scrape_date_idx
    ON gold.lot_dossier (neighborhood, scrape_date);

-- site_dossier and compare_sites arrive holding lot numbers and nothing else.
CREATE INDEX lot_dossier_lot_number_idx
    ON gold.lot_dossier (lot_number);

-- What REFRESH ... CONCURRENTLY requires, and a correctness guard besides.
-- See REFRESHING IT in the header.
CREATE UNIQUE INDEX lot_dossier_piece_key
    ON gold.lot_dossier (cell_partition, scrape_date, neighborhood, lot_number,
                         feature_id);

-- Autovacuum does not analyze materialized views, so without this the planner
-- reads 168 631 rows as its hardcoded default and is back to guessing - which
-- is the whole reason this is materialized. Any REFRESH wants it too.
ANALYZE gold.lot_dossier;


COMMENT ON MATERIALIZED VIEW gold.lot_dossier IS

    'One row per lot x zone piece: the ground, the roll, the grid, the solved '
    'programme and the gap between them. Filter on (neighborhood, '
    'scrape_date); add is_primary_zone for one row per lot. Columns prefixed '
    'parcel_ are whole-parcel facts repeated across its pieces - never SUM '
    'them. Materialized: stale until refreshed after a gold chain run. See '
    'hbu_infra/sql/034_gold_lot_dossier.sql.';


-- Same handover as every other file here: created by whoever runs db-init,
-- owned by the role that owns the schemas, readable by the read-only role the
-- agent's generated queries are meant to run as.
DO $$
DECLARE
    app_role text := 'urban_rag';
    ro_role  text := 'urban_rag_ro';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
        RETURN;
    END IF;
    EXECUTE format('ALTER MATERIALIZED VIEW gold.lot_dossier OWNER TO %I', app_role);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON gold.lot_dossier TO %I', ro_role);
    END IF;
END
$$;
