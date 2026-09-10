-- gold.lot_investment_opportunities — the under-built sites worth looking at
-- first, faceted by investment thesis and ranked within it. One row per
-- (lot, zone), following sql/018 and sql/019.
--
-- sql/019 answers *how far is this ground from its highest and best use* for
-- every piece of every parcel in the borough. That is the right question and
-- the wrong shape to act on: twenty-odd thousand rows, most of them
-- uninteresting, sorted by nothing and faceted by nothing. This table is that
-- one turned into a shortlist.
--
-- A parcel a zoning boundary crosses can carry **two theses**, and regularly
-- does: a commercial strip worth redeveloping in front of a yard that is not.
-- Collapsing the two would mean throwing one away, so both are ranked, and
-- `lot_number` is what puts them back together on a screen.
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
-- sql/019 and sql/018, one join away on `(lot_uid, feature_id)`. What is carried
-- here is what
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
    -- The zone, and the second half of the key. sql/018 and sql/019 are keyed
    -- on the pair because a zoning boundary crossing a large parcel makes two
    -- sites of it, each with its own program and its own yield; a shortlist
    -- that collapsed them would have to throw one away. See sql/018's header.
    feature_id   text NOT NULL,
    -- Infolot's own number, carried because it is what survives a reload and
    -- what a person reads out to a colleague — and, here, because it is what
    -- groups a parcel's pieces back together on a screen.
    lot_number   text,
    -- The parcel, and the ground this row's program was solved over.
    lot_area_m2        double precision,
    piece_area_m2      double precision,
    num_lot_zones      integer,
    is_primary_zone    boolean,
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
    -- The zone is in the key: one row per piece of ground, following
    -- gold.lot_highest_best_use. See sql/018's header for why a parcel is
    -- not always one site.
    PRIMARY KEY (scrape_date, neighborhood, lot_uid, feature_id)
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

-- ---------------------------------------------------------------------------
-- Widening: the second axis - why the site is acquirable
-- ---------------------------------------------------------------------------
--
-- `investment_thesis` above names what you would build. `site_thesis` names
-- why the parcel is on the market at all, and is one of four values plus
-- 'none', in the order the asset resolves them when more than one holds:
--
--   * 'brownfield'  - the dominant use standing on the lot is one Quebec's
--                     contaminated-land regime presumes against (manufacturing,
--                     garages, service stations, warehousing, salvage), and the
--                     governing zone is not a secteur d'interet patrimonial.
--                     Deliberately not screened on is_underbuilt: what changes
--                     on a gas station is the use, not the floor.
--   * 'teardown'    - a building old enough to be presumed obsolete, filling
--                     little of its envelope, under a grid that allows storeys
--                     above it, outside a heritage sector.
--   * 'infill'      - nothing stands on the lot and the solver has a program.
--   * 'improvement' - the building stays and gains a storey on its own
--                     footprint or an annex on the ground the solver's
--                     footprint covers and the standing one does not.
--
-- The four is_*_site booleans say which held, so a lot filed under brownfield
-- can still be read as a teardown. The thresholds, the cost rates and the
-- heritage switches are all config and all land in `screen_assumptions`.
--
-- **Heritage.** heritage_sector and piia_sector are the governing zone's own
-- *Secteur d'interet patrimonial* and *PIIA (secteur)* rows, read off the grid
-- PDF by silver.zoning_grid_columns. is_heritage_sector and has_piia_review
-- each keep a lot out of the two theses that demolish - the PIIA reviews how a
-- replacement building meets the street, which is the case a teardown puts to
-- it - leaving it its improvement thesis, where the building stays;
-- demolition_review_required is the sector or a building older than 1940,
-- which is where the Loi sur le patrimoine culturel obliges the borough's
-- demolition by-law to apply;
-- is_demolition_restricted is whichever of those the run's config screened on,
-- and only on a lot with standing floor to demolish: where the roll states no
-- floor there is no demolition to refer to committee, and screening there put
-- a contamination-risk use into infill - the one thesis meaning nothing stands
-- on the lot - because infill does not read this flag either. Lot 2 249 816
-- (CUBF 6419, PIIA sector, no stated floor) was that case.
--
-- **The lane screen.** infill is the one thesis ground the roll never listed
-- can reach - the other three need a use code or a stated floor - and a
-- ruelle, a park remnant or a street sliver reads exactly like a vacant lot
-- to it: no floor, no dwellings, an envelope and a program. What tells them
-- apart is the *measured* footprint, silver.lot_zone_pieces' clip of the
-- cadastre's buildings onto the piece, which the gap carries.
-- existing_footprint_coverage is that footprint over the piece's ground;
-- is_unassessed_vacant is "nothing on the roll at all - no unit, no value,
-- no floor, no dwelling, no use code - and under unassessed_vacant_max_coverage
-- (0.05) of the ground under a building", and a lot it holds on is not an
-- infill. Either condition alone is a site: an assessed parking lot with
-- nothing on it is the infill thesis's own case, and the roll's silence
-- alone is not enough because the unit count is footprint-allocated across a
-- split parcel's pieces and rounds to zero on a bare yard behind an assessed
-- building. Lot 2 249 035 (920 m2, 16.7 m2 of a neighbour's building on it,
-- nothing on the roll, no frontage) was the case; 594 of VSMPE 2026-09-01's
-- 1,051 infill pieces, with a median 3.7 m of frontage, went with it.
--
-- **Each thesis costs its own denominator.** For the three that clear the
-- ground:
--
--     site_yield_on_cost_pct = 100 * hbu_annual_stabilised_noi_cad
--        / (hbu_total_capital_cost_cad + land + demolition_cost_cad
--           + site_assessment_cost_cad + remediation_cost_cad)
--
-- and for an improvement the building stays, so the yield is the addition's
-- own: improvement_noi_cad over improvement_cost_cad. site_thesis_rank is
-- within the site thesis on that yield, tiebroken on the verdict
-- (redevelopment_npv_gain_cad, or improvement_noi_cad), and
-- is_top_site_opportunity marks the first site_top_n. A lot is ranked only
-- where the verdict is positive - config, `require_positive_npv` - and keeps
-- its site thesis either way.
--
-- **Read across lot_uid, not on it**, for the reason sql/019's header gives:
-- the map joins this table to rag.lots on (neighborhood, scrape_date,
-- lot_number).
--
-- ADD COLUMN IF NOT EXISTS, like every widening here, so a partition written
-- before the second axis existed keeps its rows with these NULL.
ALTER TABLE gold.lot_investment_opportunities
    -- what the screen read, carried so a row explains itself
    ADD COLUMN IF NOT EXISTS existing_year_built            integer,
    ADD COLUMN IF NOT EXISTS existing_num_storeys           integer,
    ADD COLUMN IF NOT EXISTS existing_dominant_use_code     text,
    ADD COLUMN IF NOT EXISTS existing_footprint_m2          double precision,
    ADD COLUMN IF NOT EXISTS hbu_floors                     integer,
    ADD COLUMN IF NOT EXISTS hbu_footprint_m2               double precision,
    ADD COLUMN IF NOT EXISTS grid_zone                      text,
    ADD COLUMN IF NOT EXISTS heritage_sector                text,
    ADD COLUMN IF NOT EXISTS piia_sector                    text,
    ADD COLUMN IF NOT EXISTS storey_headroom                integer,
    ADD COLUMN IF NOT EXISTS built_share                    double precision,
    -- the measured footprint over the piece's ground - not the roll, and
    -- not existing_footprint_m2 above, which is the roll's floor over its
    -- storeys; null on a partition older than silver.lot_zone_pieces
    ADD COLUMN IF NOT EXISTS existing_footprint_coverage    double precision,
    ADD COLUMN IF NOT EXISTS redevelopment_npv_gain_cad     double precision,
    -- the flags
    ADD COLUMN IF NOT EXISTS is_brownfield_use              boolean,
    ADD COLUMN IF NOT EXISTS is_unassessed_vacant           boolean,
    ADD COLUMN IF NOT EXISTS is_heritage_sector             boolean,
    ADD COLUMN IF NOT EXISTS has_piia_review                boolean,
    ADD COLUMN IF NOT EXISTS demolition_review_required     boolean,
    ADD COLUMN IF NOT EXISTS is_demolition_restricted       boolean,
    ADD COLUMN IF NOT EXISTS is_brownfield_site             boolean,
    ADD COLUMN IF NOT EXISTS is_teardown_site               boolean,
    ADD COLUMN IF NOT EXISTS is_infill_site                 boolean,
    ADD COLUMN IF NOT EXISTS is_improvement_site            boolean,
    ADD COLUMN IF NOT EXISTS site_thesis                    text,
    -- the improvement program
    ADD COLUMN IF NOT EXISTS improvement_added_storeys      integer,
    ADD COLUMN IF NOT EXISTS improvement_floor_m2           double precision,
    ADD COLUMN IF NOT EXISTS improvement_cost_cad           double precision,
    ADD COLUMN IF NOT EXISTS improvement_noi_cad            double precision,
    ADD COLUMN IF NOT EXISTS improvement_yield_pct          double precision,
    -- the site costs and the yield on them
    ADD COLUMN IF NOT EXISTS demolition_cost_cad            double precision,
    ADD COLUMN IF NOT EXISTS site_assessment_cost_cad       double precision,
    ADD COLUMN IF NOT EXISTS remediation_cost_cad           double precision,
    ADD COLUMN IF NOT EXISTS site_total_project_cost_cad    double precision,
    ADD COLUMN IF NOT EXISTS site_yield_on_cost_pct         double precision,
    -- the rank within the site thesis
    ADD COLUMN IF NOT EXISTS site_thesis_rank               integer,
    ADD COLUMN IF NOT EXISTS is_top_site_opportunity        boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS num_ranked_in_site_thesis      integer;

-- "The teardowns in this borough, best first" - the second axis's own read,
-- partial for the reason the first axis's index is.
CREATE INDEX IF NOT EXISTS lot_investment_opportunities_site_thesis_idx
    ON gold.lot_investment_opportunities (site_thesis, site_thesis_rank)
    WHERE site_thesis_rank IS NOT NULL;
-- The map's join: the lot's shape by its cadastral number within the
-- partition, and only for the lots that carry a site thesis at all.
CREATE INDEX IF NOT EXISTS lot_investment_opportunities_site_lot_idx
    ON gold.lot_investment_opportunities (neighborhood, scrape_date, lot_number)
    WHERE site_thesis IS NOT NULL AND site_thesis <> 'none';

-- ---------------------------------------------------------------------------
-- Widening: the three futures, for the owner and for a buyer
-- ---------------------------------------------------------------------------
--
-- sql/019 now holds three futures per lot - hold, enhance (the building
-- retained and grown, a second CP-SAT solve), rebuild - on the owner's
-- footing, land cancelling and before the site's costs. This table carries
-- them through (enhance_* and hold/enhance/rebuild_value_cad, best_future)
-- and prices them twice more:
--
--   * for the **owner**: owner_*_value_cad with the demolition, the
--     characterisation and the remediation taken off the rebuild;
--     owner_gain_enhance_cad and owner_gain_rebuild_cad against holding;
--     owner_best_future the largest, 'hold' on a tie.
--   * for a **buyer**: acquisition_cost_cad is the larger of the roll's
--     assessed value times market_value_factor and the standing income's
--     present value - a seller keeps the better of the two; buyer_npv_*_cad
--     is each future's value less that price; buyer_yield_*_pct the future's
--     stabilised NOI over everything paid to reach it; residual_price_*_cad
--     the most a buyer could pay and still clear the discount rate;
--     buyer_best_future the largest NPV, or 'none' where even that is
--     below zero - the buyer walks. NULL where the roll never assessed
--     the lot, since there is no price to pay.
--
-- site_verdict_cad is what the site thesis's rank breaks ties on and what
-- require_positive_npv screens: the owner's gain from rebuilding on the three
-- theses that clear the ground, the addition's gain on an improvement.
-- improvement_source says whether the improvement is the gap's solve or the
-- closed-form estimate a partition without one falls back to.
--
-- `land_value_factor` in screen_assumptions is `market_value_factor` from
-- here on: it always scaled rl0404a, which is land and building together.
ALTER TABLE gold.lot_investment_opportunities
    ADD COLUMN IF NOT EXISTS existing_present_value_cad              double precision,
    ADD COLUMN IF NOT EXISTS hbu_npv_cad                             double precision,
    ADD COLUMN IF NOT EXISTS enhance_status                          text,
    ADD COLUMN IF NOT EXISTS enhance_solved                          boolean,
    ADD COLUMN IF NOT EXISTS enhance_solve_error                     text,
    ADD COLUMN IF NOT EXISTS enhance_floors                          integer,
    ADD COLUMN IF NOT EXISTS enhance_added_storeys                   integer,
    ADD COLUMN IF NOT EXISTS enhance_footprint_m2                    double precision,
    ADD COLUMN IF NOT EXISTS enhance_gross_floor_area_m2             double precision,
    ADD COLUMN IF NOT EXISTS enhance_added_floor_area_m2             double precision,
    ADD COLUMN IF NOT EXISTS enhance_added_dwellings                 integer,
    ADD COLUMN IF NOT EXISTS enhance_num_dwellings                   integer,
    ADD COLUMN IF NOT EXISTS enhance_units                           jsonb,
    ADD COLUMN IF NOT EXISTS enhance_added_commercial_area_m2        double precision,
    ADD COLUMN IF NOT EXISTS enhance_added_industrial_area_m2        double precision,
    ADD COLUMN IF NOT EXISTS enhance_surface_stalls                  integer,
    ADD COLUMN IF NOT EXISTS enhance_capital_cost_cad                double precision,
    ADD COLUMN IF NOT EXISTS enhance_added_annual_gross_income_cad   double precision,
    ADD COLUMN IF NOT EXISTS enhance_added_annual_stabilised_noi_cad double precision,
    ADD COLUMN IF NOT EXISTS enhance_present_value_cad               double precision,
    ADD COLUMN IF NOT EXISTS enhance_npv_cad                         double precision,
    ADD COLUMN IF NOT EXISTS enhance_disruption_cad                  double precision,
    ADD COLUMN IF NOT EXISTS enhance_gain_cad                        double precision,
    ADD COLUMN IF NOT EXISTS enhance_binding                         jsonb,
    ADD COLUMN IF NOT EXISTS hold_value_cad                          double precision,
    ADD COLUMN IF NOT EXISTS enhance_value_cad                       double precision,
    ADD COLUMN IF NOT EXISTS rebuild_value_cad                       double precision,
    ADD COLUMN IF NOT EXISTS best_future                             text,
    ADD COLUMN IF NOT EXISTS enhance_assumptions                     jsonb,
    ADD COLUMN IF NOT EXISTS improvement_source                      text,
    ADD COLUMN IF NOT EXISTS site_costs_cad                          double precision,
    ADD COLUMN IF NOT EXISTS site_verdict_cad                        double precision,
    ADD COLUMN IF NOT EXISTS owner_hold_value_cad                    double precision,
    ADD COLUMN IF NOT EXISTS owner_enhance_value_cad                 double precision,
    ADD COLUMN IF NOT EXISTS owner_rebuild_value_cad                 double precision,
    ADD COLUMN IF NOT EXISTS owner_gain_enhance_cad                  double precision,
    ADD COLUMN IF NOT EXISTS owner_gain_rebuild_cad                  double precision,
    ADD COLUMN IF NOT EXISTS owner_best_future                       text,
    ADD COLUMN IF NOT EXISTS acquisition_cost_cad                    double precision,
    ADD COLUMN IF NOT EXISTS buyer_npv_hold_cad                      double precision,
    ADD COLUMN IF NOT EXISTS buyer_npv_enhance_cad                   double precision,
    ADD COLUMN IF NOT EXISTS buyer_npv_rebuild_cad                   double precision,
    ADD COLUMN IF NOT EXISTS buyer_yield_hold_pct                    double precision,
    ADD COLUMN IF NOT EXISTS buyer_yield_enhance_pct                 double precision,
    ADD COLUMN IF NOT EXISTS buyer_yield_rebuild_pct                 double precision,
    ADD COLUMN IF NOT EXISTS residual_price_enhance_cad              double precision,
    ADD COLUMN IF NOT EXISTS residual_price_rebuild_cad              double precision,
    ADD COLUMN IF NOT EXISTS buyer_best_future                       text;

CREATE INDEX IF NOT EXISTS lot_investment_opportunities_owner_future_idx
    ON gold.lot_investment_opportunities (owner_best_future)
    WHERE owner_best_future IS NOT NULL AND owner_best_future <> 'hold';
CREATE INDEX IF NOT EXISTS lot_investment_opportunities_buyer_future_idx
    ON gold.lot_investment_opportunities (buyer_best_future)
    WHERE buyer_best_future IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Widening: the returns - yield on all-in cost, IRR, and the screens
-- ---------------------------------------------------------------------------
--
-- The futures above are present values. These are the proforma around them
-- (urban_rag.proforma): the budget with soft costs, contingency and
-- builder's-risk insurance on the hard cost, the site's costs and the
-- acquisition; a timeline that spends it over the build, fills the income
-- over a lease-up that is the longer of the solve's months and what an
-- absorption rate says the dwellings take, holds, and sells at the terminal
-- cap less selling costs; and the unlevered IRR of that stream, twice - the
-- buyer's on the whole building after paying for the lot, the owner's on the
-- increment over the building they have.
--
-- site_irr_pct and site_all_in_yield_on_cost_pct are the buyer's on the
-- thesis's own future (the enhancement on an improvement, the rebuild on the
-- rest). is_good_candidate is the screen: that yield at least
-- min_yoc_spread_bps over market_cap_rate_pct or that IRR at least
-- hurdle_irr_pct (either bar; clears_cap_rate and clears_hurdle say which),
-- and the owner's verdict above zero. site_thesis_rank is on
-- the IRR from here on, the yield the tiebreak. comparable_cap_rate_pct is
-- what the roll implies for the lots around this one, carried for the reader
-- and not what the screen holds the yield against.
ALTER TABLE gold.lot_investment_opportunities
    ADD COLUMN IF NOT EXISTS comparable_cap_rate_pct                 double precision,
    ADD COLUMN IF NOT EXISTS rebuild_budget_cad                      double precision,
    ADD COLUMN IF NOT EXISTS rebuild_soft_cost_cad                   double precision,
    ADD COLUMN IF NOT EXISTS rebuild_contingency_cad                 double precision,
    ADD COLUMN IF NOT EXISTS rebuild_builders_risk_cad               double precision,
    ADD COLUMN IF NOT EXISTS rebuild_lease_up_months                 integer,
    ADD COLUMN IF NOT EXISTS rebuild_total_development_cost_cad      double precision,
    ADD COLUMN IF NOT EXISTS enhance_budget_cad                      double precision,
    ADD COLUMN IF NOT EXISTS enhance_lease_up_months                 integer,
    ADD COLUMN IF NOT EXISTS enhance_total_development_cost_cad      double precision,
    ADD COLUMN IF NOT EXISTS market_cap_rate_pct                     double precision,
    ADD COLUMN IF NOT EXISTS buyer_yoc_hold_pct                      double precision,
    ADD COLUMN IF NOT EXISTS buyer_yoc_enhance_pct                   double precision,
    ADD COLUMN IF NOT EXISTS buyer_yoc_rebuild_pct                   double precision,
    ADD COLUMN IF NOT EXISTS buyer_irr_hold_pct                      double precision,
    ADD COLUMN IF NOT EXISTS buyer_irr_enhance_pct                   double precision,
    ADD COLUMN IF NOT EXISTS buyer_irr_rebuild_pct                   double precision,
    ADD COLUMN IF NOT EXISTS buyer_multiple_rebuild                  double precision,
    ADD COLUMN IF NOT EXISTS buyer_multiple_enhance                  double precision,
    ADD COLUMN IF NOT EXISTS owner_yoc_rebuild_pct                   double precision,
    ADD COLUMN IF NOT EXISTS owner_yoc_enhance_pct                   double precision,
    ADD COLUMN IF NOT EXISTS owner_irr_rebuild_pct                   double precision,
    ADD COLUMN IF NOT EXISTS owner_irr_enhance_pct                   double precision,
    ADD COLUMN IF NOT EXISTS yoc_spread_rebuild_bps                  double precision,
    ADD COLUMN IF NOT EXISTS yoc_spread_enhance_bps                  double precision,
    ADD COLUMN IF NOT EXISTS site_irr_pct                            double precision,
    ADD COLUMN IF NOT EXISTS owner_site_irr_pct                      double precision,
    ADD COLUMN IF NOT EXISTS site_all_in_yield_on_cost_pct           double precision,
    ADD COLUMN IF NOT EXISTS site_yoc_spread_bps                     double precision,
    ADD COLUMN IF NOT EXISTS clears_cap_rate                         boolean,
    ADD COLUMN IF NOT EXISTS clears_hurdle                           boolean,
    ADD COLUMN IF NOT EXISTS is_good_candidate                       boolean NOT NULL DEFAULT false;

-- "The good candidates, best IRR first" - the read this widening is for.
CREATE INDEX IF NOT EXISTS lot_investment_opportunities_good_idx
    ON gold.lot_investment_opportunities (site_thesis, site_irr_pct DESC)
    WHERE is_good_candidate;

-- ---------------------------------------------------------------------------
-- Widening: a return that knows the building is not all dwellings
-- ---------------------------------------------------------------------------
--
-- The returns above were shaped for an apartment block. Two of their terms are
-- about dwellings specifically, and the solver has been filling envelopes with
-- three families for as long as they have existed — so a lot whose zoning grid
-- keeps housing off the ground floor (*Tous sauf le RDC*) and lets a C.4 take
-- every level came back priced as a building it is not:
--
--   * **the lease-up** was dwellings over absorption_units_per_month, so a
--     program with no dwellings filled in the solve's stated months however
--     much floor it held — fifteen thousand square feet of retail leased as
--     fast as an empty six-plex. It is now the longest of that, the commercial
--     floor over commercial_absorption_sqft_per_month, and the industrial floor
--     over its own rate. The longest and not the sum: the families fill in
--     parallel.
--   * **the exit** capitalised every dollar at the multifamily terminal cap.
--     market_cap_rate_pct is now blended per lot — each family's cap is the
--     residential one plus its own spread (commercial_cap_rate_spread_bps,
--     industrial_cap_rate_spread_bps in screen_assumptions), weighted by how
--     much of that lot's NOI the family earns. Weighted by *income*, never by
--     floor: commerce earns about four times what housing does per square
--     foot, so a floor weighting would put a mixed building's exit far nearer
--     the apartment cap than its rent roll justifies. gold.
--     lot_redevelopment_gap's hbu_commercial_noi_cad and its neighbours are
--     the weight, and they are carried onto this table for the reader.
--
-- market_cap_rate_pct is therefore per-lot from here on rather than one
-- number per partition, and yoc_spread_rebuild_bps is measured against the
-- lot's own blend — so is_good_candidate asks a retail scheme for the yield
-- its own exit implies instead of letting it through on an apartment's.
-- exit_cap_rate_*_pct is what each future is actually *sold* at inside the
-- IRR (the solve's terminal cap, blended the same way), reported so a reader
-- can see why two lots with the same yield have different IRRs.
--
-- Both corrections push a commerce-heavy lot's stated return down. That is the
-- point rather than a regression: it was previously being leased at housing's
-- speed and sold at housing's cap, and neither was a number anyone chose. The
-- income itself never moved — the solve has always priced every square foot of
-- commerce it builds, and it has always been in the yield's numerator.
--
-- *_non_residential_income_share is the weight behind both caps, and the
-- column that says at a glance whether a lot is a mixed-use answer at all.
-- NULL where the future has no income rather than 0, since a lot with no
-- program and an all-residential one are not the same answer.
ALTER TABLE gold.lot_investment_opportunities
    ADD COLUMN IF NOT EXISTS hbu_residential_noi_cad                  double precision,
    ADD COLUMN IF NOT EXISTS hbu_commercial_noi_cad                   double precision,
    ADD COLUMN IF NOT EXISTS hbu_industrial_noi_cad                   double precision,
    ADD COLUMN IF NOT EXISTS hbu_commercial_floor_area_with_cellar_m2 double precision,
    ADD COLUMN IF NOT EXISTS hbu_industrial_floor_area_with_cellar_m2 double precision,
    ADD COLUMN IF NOT EXISTS enhance_added_residential_noi_cad        double precision,
    ADD COLUMN IF NOT EXISTS enhance_added_commercial_noi_cad         double precision,
    ADD COLUMN IF NOT EXISTS enhance_added_industrial_noi_cad         double precision,
    ADD COLUMN IF NOT EXISTS market_cap_rate_enhance_pct              double precision,
    ADD COLUMN IF NOT EXISTS exit_cap_rate_rebuild_pct                double precision,
    ADD COLUMN IF NOT EXISTS exit_cap_rate_enhance_pct                double precision,
    ADD COLUMN IF NOT EXISTS hbu_non_residential_income_share         double precision,
    ADD COLUMN IF NOT EXISTS enhance_non_residential_income_share     double precision;

-- ---------------------------------------------------------------------------
-- Widening: the parking waived, on both futures
-- ---------------------------------------------------------------------------
--
-- Whether the rebuild (hbu_*) and the enhancement (enhance_*) only exist with
-- their stalls waived, and how many stalls each owes at the solve's ratios if
-- so - sql/017 for the rule, sql/018 and sql/019 for the two rows these are
-- read off. On the shortlist because a reader pricing either column has to
-- know it stands on a parking variance before calling anyone: the budget
-- behind buyer_npv_rebuild_cad carries no parking on such a row, and the
-- Deal pane says so beside the number.
--
-- NULL where the future was never solved, like the columns they describe.
ALTER TABLE gold.lot_investment_opportunities
    ADD COLUMN IF NOT EXISTS hbu_parking_waived     boolean,
    ADD COLUMN IF NOT EXISTS hbu_waived_stalls      integer,
    ADD COLUMN IF NOT EXISTS enhance_parking_waived boolean,
    ADD COLUMN IF NOT EXISTS enhance_waived_stalls  integer;

-- "The mixed-use candidates, most commerce first" - the read this widening is
-- for, and the one a residential-only screen could not ask.
CREATE INDEX IF NOT EXISTS lot_investment_opportunities_mixed_idx
    ON gold.lot_investment_opportunities (hbu_non_residential_income_share DESC)
    WHERE hbu_non_residential_income_share > 0;

-- ---------------------------------------------------------------------------
-- Widening: the IRR bar is the lot's own, and the blend values the parts
-- ---------------------------------------------------------------------------
--
-- Two corrections to the screens above, both about the same arithmetic.
--
-- **The blended cap is now the harmonic mean, not the arithmetic one.** A
-- building of two income streams is worth sum(NOI_f / cap_f) — each stream
-- sold to the market that buys it — so the single cap reproducing that price
-- is sum(NOI_f) / sum(NOI_f / cap_f), and total NOI / cap is then the
-- parts-sum by construction. An NOI-weighted arithmetic mean is always the
-- larger of the two and so always valued a mixed building *under* its parts:
-- 14 bps high and 2.65 pct cheap on a 50/50 split, 9 to 13 bps on the real
-- Villeray mixed lots. market_cap_rate_pct and exit_cap_rate_*_pct therefore
-- move down slightly on mixed rows and are unchanged on pure ones.
--
-- **And the IRR hurdle is a spread over that cap rather than a flat level.**
-- In a flat-NOI model the cap rate IS the unlevered return: buy at a 4.5 cap,
-- collect a flat 4.5 forever, sell at 4.5, and the IRR is 4.5 (4.44 after
-- selling costs). So the cap is the *indifference* point — what buying the
-- finished building pays — and a hurdle set at it prices development risk at
-- zero. The bar is the lot's own blended cap plus hurdle_irr_spread_bps, the
-- same 100 bps the yield test uses, so the two screens became two views of
-- one bar instead of two bars seven points apart.
--
-- That the old 12 pct was seven points away is not a figure of speech: a deal
-- exactly clearing the 100 bps yield test scores a 5.55 pct IRR here, and
-- clearing 12 pct needed a 12 pct yield on cost — 750 bps over the cap, a
-- 2.7x value on cost. 12 is a levered, growth-carrying convention; this model
-- has neither, and a 6 pct YoC deal reaches 12 pct only at 6.3 pct annual NOI
-- growth. screen_assumptions carries hurdle_irr_pct (null when derived) and
-- hurdle_irr_spread_bps on every row, so which regime produced a flag is
-- readable from the row.
--
-- site_hurdle_irr_pct is that bar per lot — a pass/fail whose threshold is not
-- on the row cannot be checked a month later.
ALTER TABLE gold.lot_investment_opportunities
    ADD COLUMN IF NOT EXISTS site_hurdle_irr_pct double precision;
