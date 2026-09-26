-- gold.lot_redevelopment_gap — how far each piece of ground is from its
-- highest and best use. One row per (lot, zone).
--
-- Downstream of gold.lot_highest_best_use (sql/018) and silver.
-- lot_assessment_comparables (sql/016), and the comparison both exist to make
-- possible: the floor area and the dwellings the assessment roll says stand on
-- a lot today, against the floor area and dwellings its zoning envelope could
-- hold, and the two incomes on one stated definition of NOI.
-- Written by hbu_dataplatform's `lot_redevelopment_gap` asset — see that
-- repo's `urban_rag.hbu.use_gap`.
--
-- **The grain is sql/018's**, for sql/018's reason: a zoning boundary crossing
-- a large parcel makes two development sites of it, each with its own envelope
-- and its own programme, so each has its own gap. What is particular to *this*
-- table is the other side of the subtraction — the roll describes a **lot**,
-- so it has to be divided between that lot's pieces before anything can be
-- taken away from it. `footprint_share` is that division and it is measured
-- rather than assumed; see the columns below and sql/025.
--
-- **This table is the comparison, and not a second copy of the envelope.**
-- Everything about the *program* itself — the storey split, the stalls, the
-- binding caps, the dollar figures of what it costs to build — is gold.
-- lot_highest_best_use's, one join away on `(lot_uid, feature_id)`; the pair,
-- because joining on the lot alone multiplies the split parcels. The "two tables rather
-- than more columns on one" reasoning sql/016's header gives for splitting
-- lot_assessed_values from lot_assessment_comparables applies again here: a
-- reader who wants the envelope in full already has a table for it, and this
-- one's whole job is the subtraction.
--
-- ---------------------------------------------------------------------------
-- Reconciling two things that are not otherwise subtractable
-- ---------------------------------------------------------------------------
--
-- The existing side is silver.lot_assessment_comparables' own — carried, not
-- recomputed, so the two tables cannot disagree about what a standing building
-- earns. The proposed side is gold.lot_highest_best_use's. Putting them beside
-- each other means reconciling three things first, each a way to be
-- confidently wrong:
--
-- **The period.** hbu_dataplatform's development solver returns income a
-- *month* (CMHC surveys a monthly rent); the assessment side is a *year*
-- (commercial leasing is quoted annually, and the roll is read against annual
-- figures). Every money column below is annual, in its name as well as its
-- value.
--
-- **The definition of NOI.** silver.lot_assessment_comparables nets an
-- `operating_expense_ratio` off the gross and charges nothing for the
-- building, because the building is already standing. The development solver
-- nets the amortised cost of *putting the building up* and takes no operating
-- expense off. Subtracting one from the other would compare a stabilised
-- income against a development margin and answer neither question, so this
-- table states one definition — `gross * (1 - operating_expense_ratio)`, the
-- same ratio silver.lot_assessment_comparables was run at, read off its own
-- `income_assumptions` rather than configured a second time — and computes
-- both sides under it. `annual_stabilised_noi_gap_cad` is the two put beside
-- each other; `hbu_annual_noi_after_construction_cad` is the solver's own
-- objective, annualised and kept under a name that says what it nets, with
-- `hbu_total_capital_cost_cad` beside it because what a redevelopment earns
-- and what it costs to get there are two numbers and this table states both
-- rather than discounting them into a verdict.
--
-- **Gross floor area against a unit schedule.** The roll's floor area is
-- corridors and cores included. `hbu_residential_floor_area_m2` is the plate
-- the dwellings actually occupy (`footprint x residential_floors` on
-- gold.lot_highest_best_use), which is the like-for-like comparison; the
-- narrower rentable schedule the revenue was priced from is
-- `hbu_unit_area_m2`, carried beside it because the gap between the two is the
-- corridors the residential rate quietly leaves unpriced.
--
-- ---------------------------------------------------------------------------
-- Reading the columns
-- ---------------------------------------------------------------------------
--
-- Every gap is `hbu - existing` and is NULL where either side is, because a
-- lot the roll never reached is not a lot with no floor on it —
-- `has_assessment` says which. The one deliberate exception is
-- `is_underbuilt`, which reads a missing existing floor area as nothing
-- standing: a parcel with an envelope and no assessed building is exactly the
-- case that column exists to find, so it is true whenever the envelope holds
-- more than what is (or is not) assessed. A lot gold.lot_highest_best_use has
-- no program for (hbu_status <> 'solved') is neither built out nor
-- under-built — is_underbuilt is false and every hbu_* column is NULL, the
-- same "unanswered is not the same as zero" rule the rest of this platform's
-- assessment lineage follows.
--
-- Per-class columns are named `{existing|hbu}_{class}_floor_area_m2` and
-- `{class}_floor_area_gap_{m2|sqft}` for `class` in (residential, commercial,
-- industrial), the same three CUBF-derived classes silver.
-- lot_assessment_comparables splits the roll's floor into and
-- urban_rag.program fills an envelope with — the non-residential rates behind
-- both are that module's own, which is what makes a per-class subtraction mean
-- anything. Square feet ride beside square metres on every gap column, because
-- everything upstream is metric and a gap is what gets read out loud.
--
-- No `-- requires:` header: this table names nothing outside its own schema.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO gold, public;

-- The block 004_silver_building_lots.sql explains: a table still partitioned
-- on `neighborhood` is renamed `_by_neighborhood`, its indexes and constraints
-- suffixed `_bn`, so the CREATE below makes the cell-partitioned one beside it.
DO $migrate$
DECLARE
    target  regclass := to_regclass('gold.lot_redevelopment_gap');
    old_key text;
    item    record;
    renamed text[] := '{}';
BEGIN
    IF target IS NULL THEN
        RETURN;
    END IF;

    SELECT a.attname
      INTO old_key
      FROM pg_partitioned_table p
      JOIN pg_attribute a
        ON a.attrelid = p.partrelid AND a.attnum = p.partattrs[0]
     WHERE p.partrelid = target;

    IF old_key IS DISTINCT FROM 'neighborhood' THEN
        RETURN;
    END IF;

    FOR item IN
        SELECT i.indexrelid::regclass AS index_oid, ic.relname AS name
          FROM pg_index i
          JOIN pg_class ic ON ic.oid = i.indexrelid
         WHERE i.indrelid = target
           AND NOT EXISTS (
               SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid
           )
    LOOP
        EXECUTE format(
            'ALTER INDEX %s RENAME TO %I', item.index_oid, item.name || '_bn'
        );
        renamed := renamed || item.name;
    END LOOP;

    FOR item IN
        SELECT conname AS name
          FROM pg_constraint
         WHERE conrelid = target AND contype IN ('p', 'u', 'f', 'c')
    LOOP
        EXECUTE format(
            'ALTER TABLE %s RENAME CONSTRAINT %I TO %I',
            target, item.name, item.name || '_bn'
        );
        renamed := renamed || item.name;
    END LOOP;

    EXECUTE format(
        'ALTER TABLE %s RENAME TO %I',
        target, 'lot_redevelopment_gap_by_neighborhood'
    );

    RAISE NOTICE
        'gold.lot_redevelopment_gap was LIST (neighborhood): renamed to '
        'gold.lot_redevelopment_gap_by_neighborhood; suffixed _bn: %',
        array_to_string(renamed, ', ');
END
$migrate$;

CREATE TABLE IF NOT EXISTS gold.lot_redevelopment_gap (
    -- The partition key leads, in the order 003_warehouse.sql explains; the
    -- cell columns are the lot's (028_cell_key.sql) and the borough is the
    -- lot's too, carried for the map's per-borough reads.
    scrape_date    date NOT NULL,
    cell_key       text COLLATE "C" NOT NULL,
    cell_partition text COLLATE "C" NOT NULL,
    neighborhood   text NOT NULL,
    -- Keyed on (lot_uid, feature_id), like gold.lot_highest_best_use and for
    -- both of its reasons. lot_uid rather than lot_number because a lot with
    -- an envelope and no assessed building — the parcel is_underbuilt exists
    -- to surface — has a null lot_number and cannot be the row a lot_number
    -- key would drop. And the zone, because a zoning boundary crossing a large
    -- parcel makes two sites of it, each with its own program and therefore
    -- its own gap.
    lot_uid      bigint NOT NULL,
    feature_id   text NOT NULL,
    lot_number   text,

    -- The parcel, and the ground this zone governs. The `hbu_*` side of every
    -- gap below was solved over `piece_area_m2`.
    lot_area_m2   double precision,
    piece_area_m2 double precision,
    num_lot_zones   integer,
    is_primary_zone boolean,
    primary_frontage_m double precision,

    -- -- how the parcel's assessment was divided ---------------------------
    --
    -- The roll describes a lot: one floor area, one dwelling count, one NOI,
    -- one value. The gap is per piece, so the roll is split — and how is a
    -- judgement silver.lot_zone_pieces makes and records rather than one each
    -- reader repeats. `footprint_share` divides everything the *building* is
    -- or earns and is measured off the footprints standing on this ground;
    -- `area_share` divides the land. Both sum to 1 across a lot's pieces, so a
    -- borough's totals are what they were before the split. See sql/025.
    --
    -- The consequence worth stating outright: a corner commercial strip
    -- carrying the whole of the retail block is charged the whole of it, and
    -- the yard behind it is vacant land with its full envelope still to build.
    -- Pro-rating by area would have reported nine tenths of a teardown that is
    -- not there.
    area_share            double precision,
    footprint_share       double precision,
    footprint_share_basis text,
    existing_footprint_m2 double precision,
    -- gold.lot_highest_best_use.hbu_status, restated so a reader filtering on
    -- 'solved' does not have to join back to get it.
    hbu_status   text NOT NULL,

    -- -- whether the roll reached this lot at all -----------------------
    --
    -- False on a lane, a park or a city parcel — has no assessment unit — and
    -- on any lot silver.lot_assessment_comparables' partition did not cover.
    has_assessment boolean NOT NULL DEFAULT false,
    -- True whenever the governing envelope holds more floor than the roll
    -- says stands on the lot today, reading a missing existing floor as
    -- nothing built — see the header. False, not NULL, on an unanswered lot.
    is_underbuilt  boolean NOT NULL DEFAULT false,

    -- -- floor area, per class, in both units -----------------------------
    existing_residential_floor_area_m2 double precision,
    hbu_residential_floor_area_m2      double precision,
    residential_floor_area_gap_m2      double precision,
    residential_floor_area_gap_sqft    double precision,
    existing_commercial_floor_area_m2  double precision,
    hbu_commercial_floor_area_m2       double precision,
    commercial_floor_area_gap_m2       double precision,
    commercial_floor_area_gap_sqft     double precision,
    existing_industrial_floor_area_m2  double precision,
    hbu_industrial_floor_area_m2       double precision,
    industrial_floor_area_gap_m2       double precision,
    industrial_floor_area_gap_sqft     double precision,
    -- The three classes added. NULL only when none of them was.
    existing_floor_area_m2 double precision,
    hbu_floor_area_m2      double precision,
    floor_area_gap_m2      double precision,
    floor_area_gap_sqft    double precision,
    -- The narrower rentable schedule the residential revenue was actually
    -- priced from — see the header on gross floor area vs. a unit schedule.
    hbu_unit_area_m2       double precision,

    -- -- dwellings -----------------------------------------------------
    existing_num_dwellings integer,
    hbu_num_dwellings      integer,
    dwelling_gap           integer,

    -- -- income, annual on both sides --------------------------------------
    existing_annual_gross_income_cad double precision,
    hbu_annual_gross_income_cad      double precision,
    annual_gross_income_gap_cad      double precision,
    -- What both NOIs below were netted with — silver.
    -- lot_assessment_comparables' own ratio, read off that table's
    -- income_assumptions rather than reconfigured here. The single largest
    -- lever on the two NOI columns that follow.
    operating_expense_ratio          double precision,
    existing_annual_stabilised_noi_cad double precision,
    hbu_annual_stabilised_noi_cad      double precision,
    annual_stabilised_noi_gap_cad      double precision,
    -- The development solver's own objective, annualised — income after the
    -- amortised cost of *building*, before a dollar of operating expense. A
    -- different number from the stabilised pair above and kept under a name
    -- that says what it nets, rather than a second gap column that would
    -- invite subtracting it from the wrong thing.
    hbu_annual_noi_after_construction_cad double precision,
    hbu_total_capital_cost_cad            double precision,

    -- -- what the roll says stands here, from the unit carrying most of
    -- the lot's value -----------------------------------------------------
    existing_num_assessment_units integer,
    existing_total_assessed_value numeric,
    existing_cap_rate_pct         double precision,
    existing_dominant_use_code    text,
    existing_dominant_income_class text,

    loaded_at    timestamptz NOT NULL DEFAULT now(),
    -- The zone is in the key: one row per piece of ground, following
    -- gold.lot_highest_best_use. See sql/018's header for why a parcel is
    -- not always one site.
    PRIMARY KEY (scrape_date, cell_partition, lot_uid, feature_id)
) PARTITION BY LIST (cell_partition);

-- "The most under-built lots in the cell" — the read this table exists for,
-- and the list a highest-and-best-use question starts from.
CREATE INDEX IF NOT EXISTS lot_redevelopment_gap_underbuilt_idx
    ON gold.lot_redevelopment_gap (annual_stabilised_noi_gap_cad DESC)
    WHERE is_underbuilt;
-- "Which lots the roll never reached" — the join gap this table reports on
-- its own metadata (num_with_assessment / num_without_assessment).
CREATE INDEX IF NOT EXISTS lot_redevelopment_gap_unassessed_idx
    ON gold.lot_redevelopment_gap (lot_uid)
    WHERE NOT has_assessment;
-- The map's per-borough read, which used to be partition pruning.
CREATE INDEX IF NOT EXISTS lot_redevelopment_gap_neighborhood_idx
    ON gold.lot_redevelopment_gap (neighborhood, scrape_date);

-- The discounted verdict this table used to stop short of, priced at the
-- same InvestmentAssumptions the solve ran with (carried in the hbu row's
-- program_assumptions). `hbu_npv_cad` is redeveloping: the discounted value
-- of the proposed building less its capital. `existing_present_value_cad` is
-- keeping the standing one: its stabilised NOI through the same PV factor.
-- `redevelopment_npv_gain_cad` is the difference, a missing existing side
-- read as nothing standing — the `is_underbuilt` rule, because a vacant
-- parcel is exactly the case the ranking exists to surface. The land is in
-- neither side, deliberately: the owner holds it in both futures, so it
-- cancels out of the comparison.
ALTER TABLE gold.lot_redevelopment_gap
    ADD COLUMN IF NOT EXISTS hbu_npv_cad double precision,
    ADD COLUMN IF NOT EXISTS hbu_present_value_cad double precision,
    ADD COLUMN IF NOT EXISTS existing_present_value_cad double precision,
    ADD COLUMN IF NOT EXISTS redevelopment_npv_gain_cad double precision;

-- "Where is redevelopment worth the most" — the shortlist read the verdict
-- column exists for.
CREATE INDEX IF NOT EXISTS lot_redevelopment_gap_npv_gain_idx
    ON gold.lot_redevelopment_gap (redevelopment_npv_gain_cad DESC NULLS LAST);

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
        'ALTER TABLE gold.lot_redevelopment_gap OWNER TO %I', app_role
    );

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON gold.lot_redevelopment_gap TO %I', ro_role
        );
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Widening: what stands there, in words
-- ---------------------------------------------------------------------------
--
-- An ALTER, for the reason sql/009, sql/014 and sql/016 use one.
--
-- `existing_dominant_use_code` beside this says 4611; this says "Garage de
-- stationnement pour automobiles (infrastructure)". Both are the same fact
-- about the unit carrying most of the parcel's assessed value, and only the
-- second is readable by someone scanning a shortlist of redevelopment
-- candidates — which is what this table is for.
--
-- Carried up from silver.lot_assessment_comparables, which carried it from
-- silver.assessment_units, which merged hbu_dataplatform's `cubf_use_codes`
-- snapshot of the MEFQ's Annexe 2C.1. Nothing on this path looks the code up a
-- second time.
--
-- For reading, not for filtering — `existing_dominant_use_code` is the key and
-- `existing_dominant_income_class` is what the screen in sql/021 sorts on. Two
-- editions of the manual can word one code differently.
--
-- Null where the gap has no existing side at all: a parcel with a zoning
-- envelope and nothing assessed on it, which is exactly what `is_underbuilt`
-- exists to find.
--
-- French, as published — the manual is not issued in English.
ALTER TABLE gold.lot_redevelopment_gap
    ADD COLUMN IF NOT EXISTS existing_dominant_use_description text;

-- ---------------------------------------------------------------------------
-- Widening: the second future, and the verdict across all three
-- ---------------------------------------------------------------------------
--
-- The table used to hold two futures - the standing building, discounted
-- (existing_present_value_cad), and the rebuild (hbu_npv_cad) - and the gain
-- between them. It now holds a third: the building **retained and grown**.
-- `urban_rag.hbu.solve_enhancements` runs the same CP-SAT model with the
-- standing plate and storeys as a lower bound, at most max_added_storeys on
-- top, nothing dug or decked, and the addition costed at addition_cost_premium
-- times the new-build rates; every enhance_* money figure is the *addition's*
-- own, and enhance_gross_floor_area_m2 is the whole building afterwards.
--
--   enhance_status              CP-SAT's status, or why there was nothing to
--                               solve: no_building, not_underbuilt, no_program,
--                               no_envelope, single_family_zone (the piece is
--                               zoned for one dwelling and not priced as
--                               rental at all)
--   enhance_npv_cad             the addition's present value less its capital
--   enhance_disruption_cad      the standing NOI lost while the works are on
--   enhance_gain_cad            enhance_npv_cad - enhance_disruption_cad: what
--                               enhancing adds over holding. 0, with no
--                               disruption, where the solve adds nothing
--                               (enhance_binding carries nothing_pencils):
--                               no works, so nothing is disturbed
--
-- The rebuild's income now starts only after its construction and lease-up
-- (construction_months and lease_up_months in program_assumptions), and the
-- hold's does not - so redevelopment_npv_gain_cad already carries the months
-- the site earns nothing. The three on one footing, land excluded on all of
-- them since the owner holds it either way:
--
--   hold_value_cad     = existing_present_value_cad
--   enhance_value_cad  = hold_value_cad + enhance_gain_cad
--   rebuild_value_cad  = hbu_npv_cad
--   best_future        = 'hold' | 'enhance' | 'rebuild', the largest
--
-- These are the owner's numbers before the site's own costs; the buyer's -
-- with the acquisition, the demolition and the remediation in - are on
-- gold.lot_investment_opportunities. existing_num_storeys and
-- existing_year_built travel here because the enhancement stands on the
-- first and the shortlist's teardown screen reads the second.
ALTER TABLE gold.lot_redevelopment_gap
    ADD COLUMN IF NOT EXISTS existing_num_storeys                    integer,
    ADD COLUMN IF NOT EXISTS existing_year_built                     integer,
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
    ADD COLUMN IF NOT EXISTS enhance_assumptions                     jsonb;

-- "Where does enhancing beat rebuilding" - the read the third future is for.
CREATE INDEX IF NOT EXISTS lot_redevelopment_gap_best_future_idx
    ON gold.lot_redevelopment_gap (best_future)
    WHERE best_future IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Widening: the proposal's income by use, and the floor it would lease
-- ---------------------------------------------------------------------------
--
-- The three hbu_*_floor_area_m2 columns above are a *comparison*: the roll's
-- side of this table is above-grade assessed floor, so the solver's side is
-- the above-grade plates and nothing else, or the subtraction between them
-- would be between two different definitions. That is right for the gap and
-- wrong for everything else, in two ways this widening fixes.
--
-- **The income is not split like the floor.** At the rates in
-- program_assumptions a square foot of commerce collects about four times a
-- square foot of housing, so a ground floor of shops under five storeys of
-- flats is a sixth of the building's floor and very nearly half its rent.
-- hbu_residential_noi_cad and its two neighbours are hbu_annual_stabilised_noi_cad
-- split by the family that earns it, netted with the same
-- hbu_operating_expense_ratio so the three add back to it exactly. One ratio
-- across all three is the solve's own simplification carried forward, and it
-- is the one that most flatters the dwellings: a triple-net retail lease
-- leaves its landlord a far lighter expense load than an apartment does.
--
-- What reads them is hbu_dataplatform's `urban_rag.proforma`, which blends the
-- cap rate a lot is valued and screened at over exactly these three — a shop
-- does not sell at a multifamily cap, and weighting that blend by floor would
-- hand a mixed building a cap it has no business getting.
--
-- **And the cellar is floor the building would lease.** The solve digs for
-- shops across this borough (see sql/018's basement widening), so
-- basement_commercial_area_m2 is routinely a third of the retail again on top
-- of the plate. hbu_commercial_floor_area_with_cellar_m2 and its industrial
-- twin are the whole of what would be leased, and they exist because the
-- proforma divides them by an absorption rate in square feet a month to say
-- how long the space takes to fill. Not part of any gap, and deliberately not
-- folded into the columns above: those answer the roll.
--
-- The enhancement's three are the same split on the *addition* — the new floor
-- only, since the standing building's income is
-- existing_annual_stabilised_noi_cad and is capped on what already stands.
-- They sum to enhance_added_annual_stabilised_noi_cad.
--
-- All NULL on a partition written before they existed, and the proforma reads
-- a missing split as an all-residential building — which is what it priced
-- every lot as before this.
ALTER TABLE gold.lot_redevelopment_gap
    ADD COLUMN IF NOT EXISTS hbu_residential_noi_cad                  double precision,
    ADD COLUMN IF NOT EXISTS hbu_commercial_noi_cad                   double precision,
    ADD COLUMN IF NOT EXISTS hbu_industrial_noi_cad                   double precision,
    ADD COLUMN IF NOT EXISTS hbu_commercial_floor_area_with_cellar_m2 double precision,
    ADD COLUMN IF NOT EXISTS hbu_industrial_floor_area_with_cellar_m2 double precision,
    ADD COLUMN IF NOT EXISTS enhance_added_residential_noi_cad        double precision,
    ADD COLUMN IF NOT EXISTS enhance_added_commercial_noi_cad         double precision,
    ADD COLUMN IF NOT EXISTS enhance_added_industrial_noi_cad         double precision;

-- ---------------------------------------------------------------------------
-- Widening: the enhancement's parking waived
-- ---------------------------------------------------------------------------
--
-- The addition's counterpart of parking_waived / waived_stalls on sql/017 and
-- sql/018. An enhancement parks on the yard or not at all - nothing is dug
-- under a standing building, decked over it or bayed into its ground floor -
-- and the stall demand is on the whole building, the standing shop's floor
-- included. So a lot with no yard and a shop on it had no enhancement at all
-- (enhance_status = 'INFEASIBLE') until `urban_rag.hbu.solve_enhancements`
-- started asking the second question sql/017 describes.
--
--   enhance_parking_waived  true where the addition only solves with the
--                           stalls taken out of the model; enhance_status is
--                           then the second solve's, and enhance_surface_stalls
--                           is 0 because nothing was provided
--   enhance_waived_stalls   what the whole building owes at the rebuild's
--                           ratios and does not provide
--
-- Nullable: a lot with no enhancement to solve - no_building, not_underbuilt -
-- waived nothing, and false would read as an answer.
ALTER TABLE gold.lot_redevelopment_gap
    ADD COLUMN IF NOT EXISTS enhance_parking_waived boolean,
    ADD COLUMN IF NOT EXISTS enhance_waived_stalls  integer;
