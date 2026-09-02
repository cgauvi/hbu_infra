-- gold.lot_investment_opportunities — the under-built lots worth looking at
-- first, faceted by investment thesis and ranked within it.
--
-- sql/019 answers *how far is this lot from its highest and best use* for every
-- parcel in the borough. That is the right question and the wrong shape to act
-- on: twenty-odd thousand rows, most of them uninteresting, sorted by nothing
-- and faceted by nothing. This table is that one turned into a shortlist.
--
-- It adds exactly two things and re-solves nothing. Written by
-- hbu_dataplatform's `lot_investment_opportunities` asset — see that repo's
-- `urban_rag.opportunities` and docs/opportunities.md.
--
-- ---------------------------------------------------------------------------
-- The thesis is what you would build, not what is there
-- ---------------------------------------------------------------------------
--
-- `investment_thesis` is read off the *proposed* program — the mix of
-- residential, commercial and industrial floor the solver would put on the lot
-- — and not off the existing use. A warehouse whose highest and best use is an
-- apartment block is a **residential** opportunity; filing it under industrial
-- because that is what stands there today would put it in the one facet that
-- will never look at it.
--
-- `existing_dominant_income_class` travels beside it, and the two differing is
-- a conversion play:
--
--     SELECT lot_number, existing_dominant_income_class, investment_thesis
--       FROM gold.lot_investment_opportunities
--      WHERE is_top_opportunity
--        AND existing_dominant_income_class <> investment_thesis;
--
-- The four theses are `residential`, `mixed_use`, `commercial` and
-- `industrial`, plus `none` for a lot the solver produced no program for.
-- Where the lines fall is a mandate's judgement, not a property of the data, so
-- both thresholds are config and both are recorded on every row in
-- `screen_assumptions`:
--
--   * `dominant_share` (0.85) — the share of proposed floor one class needs to
--     own the lot outright. A building seven-eighths dwellings is residential
--     even with a shop at the bottom.
--   * `mixed_min_share` (0.15) — what the *smaller* of residential and
--     commercial needs for the lot to be mixed-use instead. Roughly a ground
--     floor under five or six residential storeys, which is where the
--     commercial component stops being incidental.
--
-- The two are deliberately not complements: between them lies a band that
-- resolves to the dominant class, and that band is why one threshold would not
-- do.
--
-- ---------------------------------------------------------------------------
-- The rank is yield on cost
-- ---------------------------------------------------------------------------
--
--     yield_on_cost_pct = 100 * hbu_annual_stabilised_noi_cad
--                             / (hbu_total_capital_cost_cad + land)
--
-- Ranking on the raw NOI gap instead would sort on parcel size almost
-- regardless of what a building costs, and every facet's top ten would be the
-- ten biggest lots in the borough. Yield on cost is what a developer actually
-- compares two sites on, and it lets a small cheap parcel beat a large dear
-- one. `annual_stabilised_noi_gap_cad` is the **tiebreak**, so two sites at the
-- same yield are ordered by the dollars a year the redevelopment adds — return
-- first, size second, rather than a weighted score nobody can defend line by
-- line.
--
-- **The land is in the denominator at its assessed value**, and that is the one
-- judgement in the formula. A developer pays for the ground as well as the
-- building, and leaving it out would rank a $4M teardown beside an empty lot as
-- though they cost the same to acquire. `land_value_factor` scales it — 1.0
-- costs the land at the roll, which is honest for the reason sql/016's
-- `market_value_factor` defaults there: Quebec's *facteur comparatif* is not in
-- the published roll.
--
-- `is_land_assessed` is false where the roll never reached the lot. Its land
-- would otherwise be counted at nothing and it would rank top of every facet,
-- so `yield_on_cost_pct` and `thesis_rank` are both NULL there instead.
--
-- **`thesis_rank` is dense and within the thesis**, so rank 1 is the best
-- residential play *and* the best industrial one. A single borough-wide rank
-- would bury every facet under whichever happens to yield best, which is
-- exactly what faceting is for.
--
-- ---------------------------------------------------------------------------
-- Every lot keeps its row
-- ---------------------------------------------------------------------------
--
-- A lot that is not under-built, one the solver found no program for, and one
-- the roll never assessed each keep a row with a NULL `thesis_rank` and a
-- reason: `is_underbuilt`, `investment_thesis = 'none'` and `is_land_assessed`
-- respectively. The table is an inventory with a shortlist marked in it, not
-- the shortlist alone — the same reason gold.lot_profiles kept every lot rather
-- than replacing rag.vacant_lots with a narrower selection. A screen is then a
-- predicate rather than a different table.
--
-- **This is not a second copy of the gap.** The per-class square-foot
-- conversions, the binding caps, the parking and the storey counts stay in
-- sql/019 and sql/018, one join away on `lot_uid`. What is carried here is what
-- a screening question needs to decide whether to open the parcel at all.
--
-- No geometry either: a reader who wants the parcel drawn joins
-- gold.lot_profiles on `lot_number`. A second copy of every polygon to serve a
-- screening query is a copy that can go stale.
--
-- No `-- requires:` header: this table names nothing outside its own schema, so
-- it lands on the first `db.py init`.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO gold, public;

CREATE TABLE IF NOT EXISTS gold.lot_investment_opportunities (
    -- The partition key leads, in the order 003_warehouse.sql explains.
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- The bigserial rag.lots mints, and what sql/018 and sql/019 are keyed on.
    -- This table conflicts on it for that reason: it is one join away from
    -- both, and a shortlist row with no program behind it is meaningless.
    lot_uid      bigint NOT NULL,
    -- Infolot's own number, carried because it is what survives a reload and
    -- what a person reads out to a colleague.
    lot_number   text,
    lot_area_m2        double precision,
    primary_frontage_m double precision,

    -- -- the facet and the rank ---------------------------------------------
    --
    -- 'residential', 'mixed_use', 'commercial', 'industrial' or 'none'. Read
    -- off the proposed program — see the header.
    investment_thesis text,
    -- The rank within that thesis, 1 being the best yield on cost. NULL for a
    -- lot that is not under-built, has no program, or has no assessed land.
    thesis_rank       integer,
    -- Whether the lot is in the first `top_n` of its thesis. A flag over the
    -- rank rather than a second sort, so changing the shortlist length moves
    -- this column and nothing else.
    is_top_opportunity boolean NOT NULL DEFAULT false,
    -- How many lots were ranked in this lot's thesis at all. The denominator
    -- `thesis_rank` means nothing without: rank 12 of 14 and rank 12 of 900
    -- are different answers.
    num_ranked_in_thesis integer,
    -- NOI over construction plus land, in percent, as a development yield is
    -- quoted and as cap_rate_pct beside it is stored.
    yield_on_cost_pct double precision,
    -- The denominator, kept so the yield is checkable from the row.
    total_project_cost_cad numeric,
    -- False where the roll never assessed the lot, which is why its yield is
    -- NULL rather than flatteringly high. See the header.
    is_land_assessed boolean NOT NULL DEFAULT false,
    -- sql/019's own screen, carried so a reader can see why an unranked row is
    -- unranked without joining back.
    is_underbuilt boolean,
    -- Why the solver produced what it did, from sql/018.
    hbu_status    text,

    -- -- what stands there now ----------------------------------------------
    existing_dominant_income_class     text,
    existing_num_dwellings             integer,
    existing_floor_area_m2             double precision,
    existing_total_assessed_value      numeric,
    existing_cap_rate_pct              double precision,
    existing_annual_stabilised_noi_cad double precision,

    -- -- what the solver would put there ------------------------------------
    hbu_num_dwellings                 integer,
    hbu_floor_area_m2                 double precision,
    hbu_residential_floor_area_m2     double precision,
    hbu_commercial_floor_area_m2      double precision,
    hbu_industrial_floor_area_m2      double precision,
    hbu_annual_stabilised_noi_cad     double precision,
    hbu_total_capital_cost_cad        numeric,

    -- -- the gap that makes it an opportunity -------------------------------
    dwelling_gap                  integer,
    floor_area_gap_m2             double precision,
    -- The tiebreak, and the number a reader means by "the gap".
    annual_stabilised_noi_gap_cad double precision,
    -- The ratio both NOIs were netted with, carried from the comparables
    -- lineage: the largest stated lever on either side of the gap.
    operating_expense_ratio       double precision,

    -- {dominant_share, mixed_min_share, land_value_factor, top_n}. The
    -- thresholds behind `investment_thesis` and `is_top_opportunity`, on every
    -- row, because a shortlist read a month later has only the row.
    screen_assumptions jsonb NOT NULL DEFAULT '{}'::jsonb,
    attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
    loaded_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, lot_uid)
) PARTITION BY LIST (neighborhood);

-- "The top residential plays in this borough" — the read this table exists
-- for, and one predicate plus an ORDER BY once the index is here. Partial: the
-- unranked rows are the inventory, not the shortlist, and carrying every lane
-- in the borough would answer neither question.
CREATE INDEX IF NOT EXISTS lot_investment_opportunities_thesis_idx
    ON gold.lot_investment_opportunities (investment_thesis, thesis_rank)
    WHERE thesis_rank IS NOT NULL;
-- The same list ordered by return rather than by rank, for a reader who wants
-- a yield floor rather than a fixed count.
CREATE INDEX IF NOT EXISTS lot_investment_opportunities_yield_idx
    ON gold.lot_investment_opportunities (yield_on_cost_pct DESC)
    WHERE yield_on_cost_pct IS NOT NULL;
-- Joining back to the gap and the program, which is what a reader does the
-- moment a row looks interesting.
CREATE INDEX IF NOT EXISTS lot_investment_opportunities_lot_idx
    ON gold.lot_investment_opportunities (lot_uid);

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

    EXECUTE format(
        'ALTER TABLE gold.lot_investment_opportunities OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON gold.lot_investment_opportunities TO %I', ro_role);
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Widening: what stands there, in words
-- ---------------------------------------------------------------------------
--
-- An ALTER, for the reason sql/009, sql/014, sql/016 and sql/019 use one.
--
-- Every other column on this shortlist is something to sort or filter by. This
-- one is not: it is the MEFQ's own text for the use code of the unit carrying
-- most of the parcel's assessed value — "Garage de stationnement pour
-- automobiles (infrastructure)" — and it is here because a person deciding
-- which of twenty ranked parcels to open reads that faster than any ratio
-- beside it.
--
-- The *code* it describes is deliberately not carried here. It is one join
-- away on lot_uid in gold.lot_redevelopment_gap, like the forty other columns
-- this table leaves there, and `existing_dominant_income_class` above is what
-- the screen in this file actually sorts on. Do not filter on this text: two
-- editions of the manual can word one code differently.
--
-- Null where the gap had no existing side — a parcel with an envelope and
-- nothing assessed on it, which is the case `is_underbuilt` exists to find.
--
-- French, as published — the manual is not issued in English.
ALTER TABLE gold.lot_investment_opportunities
    ADD COLUMN IF NOT EXISTS existing_dominant_use_description text;
