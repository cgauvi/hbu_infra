-- gold.lot_highest_best_use — the highest and best use of every lot in a
-- borough, one row each.
--
-- Downstream of silver.lot_development_programs (sql/017) and silver.
-- lot_zoning_envelopes (sql/012), and the answer both exist to produce: every
-- lot a zone reaches, with the program of the *governing* envelope named
-- beside it. Written by hbu_dataplatform's `lot_highest_best_use` asset — see
-- that repo's `urban_rag.hbu.select_highest_best_use`.
--
-- **What "governing" means, and what it is not.** A lot can carry several
-- envelope rows for two unrelated reasons, and only one of them is a choice.
-- Within one zone, a grid authorises dwellings in more than one column and
-- distinguishes them by *Largeur du terrain min* — the column a parcel of
-- this width is written for is `select_residential_column`'s pick, carried
-- through as `governs_residential` on sql/012 and sql/017. Across zones, a lot
-- on a boundary picks up a sliver of its neighbour's zoning because two
-- publishers drew two lines — that is a mapping disagreement, not two sets of
-- rules the owner may choose between, and `pct_of_lot` is what says which line
-- is believed. So the governing row is: among the columns
-- `governs_residential` marks, the one whose zone covers most of the lot,
-- income breaking a tie between two zones covering it equally and the column
-- index breaking a tie after that.
--
-- **This table does not maximise anything.** The maximisation is inside
-- `solve_program`, over the mix a chosen envelope can hold — what is chosen
-- *here* is only which envelope, and the grid chooses it. Picking the
-- highest-earning column instead of the governing one would report a building
-- under rules the parcel may not be built to; every candidate that lost is
-- still in silver.lot_development_programs, which is where "why not the other
-- column" is answered.
--
-- **Every lot the envelopes reach keeps a row.** A lot whose every column
-- authorises commerce and not housing has no program at all, and `hbu_status`
-- says why rather than leaving a null row to be misread as a gap in the data:
--
--   solved                  a governing envelope was solved
--   no_residential_column   every envelope on this lot authorises something
--                           other than housing — solve_program refuses such a
--                           column by design, and a pure C or I zone is where
--                           this shows
--   no_governing_column     residential columns exist and none governs —
--                           almost always a lot with no measured frontage
--                           under a grid stating a width minimum, which reads
--                           as 0 m and qualifies for nothing
--   infeasible              the governing column was solved and has no
--                           feasible program — a minimum the parcel cannot
--                           meet, or stalls it has nowhere to put
--   solver_error            the governing column could not be turned into a
--                           model at all; see the program row's own
--                           solve_error on sql/017
--
-- The money and mix columns below are silver.lot_development_programs' own,
-- restated on the chosen row — see that table's header for what each one
-- means and for the reason the objective is monthly while gold.
-- lot_redevelopment_gap (sql/019) is annual.
--
-- No `-- requires:` header: this table names nothing outside its own schema.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO gold, public;

CREATE TABLE IF NOT EXISTS gold.lot_highest_best_use (
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- One row per lot the zoning layer reaches, keyed on the cadastre's own
    -- surrogate key rather than on lot_number — unlike gold.lot_profiles. A
    -- lot the roll never named still has an envelope and a status here, which
    -- is exactly the parcel gold.lot_redevelopment_gap's is_underbuilt exists
    -- to surface, so it cannot be the row a lot_number key would drop.
    lot_uid      bigint NOT NULL,
    lot_number   text,
    lot_area_m2  double precision,
    primary_frontage_m double precision,

    -- -- how much of a choice this lot actually had ---------------------
    --
    -- Candidates counted, not envelope rows: a lot under a grid with one
    -- Habitation column and three Commerce ones had one choice, and
    -- num_candidates says 1, not 4.
    num_candidates            integer NOT NULL DEFAULT 0,
    num_governing_candidates  integer NOT NULL DEFAULT 0,
    num_zones                 integer NOT NULL DEFAULT 0,
    -- One of the five values the header lists.
    hbu_status  text NOT NULL,

    -- -- the governing envelope, when there is one -----------------------
    feature_id    text,
    source_table  text,
    column_index  integer,
    grid_zone     text,
    pct_of_lot    double precision,
    usages        jsonb,
    permits_commercial boolean,
    permits_industrial boolean,
    buildable_area_m2  double precision,

    -- -- the program that fills it, restated from silver.
    -- lot_development_programs — see that table's header for every column
    -- below ---------------------------------------------------------------
    status       text,
    solved       boolean,
    solve_error  text,
    monthly_net_operating_income_cad double precision,
    annual_net_operating_income_cad  double precision,
    monthly_gross_revenue_cad        double precision,
    annual_gross_revenue_cad         double precision,
    units             jsonb,
    num_dwellings     integer,
    floors            integer,
    height_m          double precision,
    footprint_m2      double precision,
    gross_floor_area_m2   double precision,
    residential_area_m2   double precision,
    unit_area_m2          double precision,
    commercial_area_m2    double precision,
    industrial_area_m2    double precision,
    underground_area_m2   double precision,
    residential_floors           integer,
    commercial_floors            integer,
    industrial_floors            integer,
    above_grade_parking_floors   integer,
    underground_levels           integer,
    underground_stalls           integer,
    above_grade_stalls           integer,
    total_stalls                 integer,
    construction_cost_cad  double precision,
    commercial_cost_cad    double precision,
    industrial_cost_cad    double precision,
    parking_cost_cad       double precision,
    total_capital_cost_cad double precision,
    binding         jsonb,
    unpriced_types  jsonb,
    -- The assumptions the chosen program was solved with, carried rather than
    -- recomputed — the same object on the winning row of sql/017.
    program_assumptions jsonb NOT NULL DEFAULT '{}'::jsonb,

    loaded_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, lot_uid)
) PARTITION BY LIST (neighborhood);

-- "How many lots are answered, and how many of each unanswered kind" — the
-- GROUP BY hbu_status the header promises, indexed so it does not have to
-- scan the whole borough for it.
CREATE INDEX IF NOT EXISTS lot_highest_best_use_status_idx
    ON gold.lot_highest_best_use (hbu_status);
-- "The most valuable redevelopments in the borough" — the read this table is
-- for once a lot is answered. Partial, the way silver.
-- lot_assessment_comparables' cap_rate_pct index is: an unanswered lot's NOI
-- is a different question, not a low answer to this one.
CREATE INDEX IF NOT EXISTS lot_highest_best_use_noi_idx
    ON gold.lot_highest_best_use (annual_net_operating_income_cad DESC)
    WHERE solved;
-- "Every lot on a zoning boundary" — where the choice above was a real one
-- rather than the only zone reaching the parcel.
CREATE INDEX IF NOT EXISTS lot_highest_best_use_boundary_idx
    ON gold.lot_highest_best_use (lot_uid)
    WHERE num_zones > 1;

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
        'ALTER TABLE gold.lot_highest_best_use OWNER TO %I', app_role
    );

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON gold.lot_highest_best_use TO %I', ro_role
        );
    END IF;
END
$$;
