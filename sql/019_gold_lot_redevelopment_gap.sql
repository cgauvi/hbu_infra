-- gold.lot_redevelopment_gap — how far each lot is from its highest and best
-- use, one row per lot.
--
-- Downstream of gold.lot_highest_best_use (sql/018) and silver.
-- lot_assessment_comparables (sql/016), and the comparison both exist to make
-- possible: the floor area and the dwellings the assessment roll says stand on
-- a lot today, against the floor area and dwellings its governing zoning
-- envelope could hold, and the two incomes on one stated definition of NOI.
-- Written by hbu_dataplatform's `lot_redevelopment_gap` asset — see that
-- repo's `urban_rag.hbu.use_gap`.
--
-- **This table is the comparison, and not a second copy of the envelope.**
-- Everything about the *program* itself — the storey split, the stalls, the
-- binding caps, the dollar figures of what it costs to build — is gold.
-- lot_highest_best_use's, one join away on `lot_uid`. The "two tables rather
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

CREATE TABLE IF NOT EXISTS gold.lot_redevelopment_gap (
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- Keyed on lot_uid, like gold.lot_highest_best_use and for the same
    -- reason: a lot with an envelope and no assessed building — the parcel
    -- is_underbuilt exists to surface — has a null lot_number, and cannot be
    -- the row a lot_number key would drop.
    lot_uid      bigint NOT NULL,
    lot_number   text,
    lot_area_m2  double precision,
    primary_frontage_m double precision,
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
    PRIMARY KEY (scrape_date, neighborhood, lot_uid)
) PARTITION BY LIST (neighborhood);

-- "The most under-built lots in the borough" — the read this table exists
-- for, and the list a highest-and-best-use question starts from.
CREATE INDEX IF NOT EXISTS lot_redevelopment_gap_underbuilt_idx
    ON gold.lot_redevelopment_gap (annual_stabilised_noi_gap_cad DESC)
    WHERE is_underbuilt;
-- "Which lots the roll never reached" — the join gap this table reports on
-- its own metadata (num_with_assessment / num_without_assessment).
CREATE INDEX IF NOT EXISTS lot_redevelopment_gap_unassessed_idx
    ON gold.lot_redevelopment_gap (lot_uid)
    WHERE NOT has_assessment;

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
