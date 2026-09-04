-- silver.lot_development_programs — what may profitably be built under every
-- zoning envelope of one borough, one row per (lot, grid column).
--
-- The same grain and the same key as silver.lot_zoning_envelopes (sql/012):
-- one candidate program per (lot_uid, feature_id, column_index), because it is
-- the same candidate. That table states what a column of a *grille des usages
-- et des normes* permits; this one is hbu_dataplatform's
-- `urban_rag.program.solve_program` run against it — a CP-SAT model that
-- maximises monthly net operating income over the mix of dwellings, commerce,
-- industry and parking the envelope can hold. Written by that repo's
-- `lot_development_programs` asset — see `urban_rag.hbu` for the arithmetic
-- and `urban_rag.program` for the solver itself.
--
-- **Every candidate keeps its row, whether it won or lost.** A grid authorises
-- dwellings in more than one column and gold.lot_highest_best_use picks one —
-- see sql/018 — but "why not the other column" is a question with an answer,
-- and this is the table it is in. A column that authorises no dwelling at all,
-- or that the grid parser could not turn into a solver input, gets no row
-- here: it was never a candidate, and silver.zoning_grid_columns.solver_ready
-- is where that is counted from its own side.
--
-- **A failed solve costs its row, not the partition.** `status = 'ERROR'` is a
-- parcel of no area or two coverage rows that contradict each other — a
-- `urban_rag.program.ProgramError` — and `solve_error` carries what it said.
-- It is not a CP-SAT status and cannot be confused for one: 'INFEASIBLE' is the
-- solver's own answer about a parcel it *could* model, this is the absence of
-- a model at all.
--
-- ---------------------------------------------------------------------------
-- Reading the money
-- ---------------------------------------------------------------------------
--
-- `solve_program`'s objective is monthly, because CMHC surveys a monthly rent.
-- Every money column here says so in its name, and the annual ones are that
-- figure times twelve — carried because the rest of this platform's assessment
-- lineage (gold.lot_redevelopment_gap, sql/019, and silver.
-- lot_assessment_comparables, sql/016) is annual, and a column that did not say
-- which period it was in would be read against the wrong one eventually.
--
-- `net_operating_income` here nets the amortised cost of *building* the mix —
-- construction_cost_cad, the two non-residential costs and parking_cost_cad,
-- straight-line over `program_assumptions ->> 'amortization_months'` — and
-- takes no operating expense off, because there is no building standing yet to
-- operate. That is a different NOI from `silver.lot_assessment_comparables`',
-- which nets an expense ratio off a standing building and charges nothing for
-- the construction — see that table's header and sql/019, which reconciles the
-- two under one definition rather than subtracting one from the other.
--
-- `residential_area_m2` is `footprint_m2 * residential_floors` — the plate the
-- dwellings stand on, gross of corridors and cores, and the number that
-- compares like-for-like with the roll's own floor area. `unit_area_m2` is the
-- narrower rentable schedule the revenue was actually computed from
-- (`urban_rag.program.UNIT_AREAS_SQFT`), carried beside it so the gap between
-- the two — what the residential rate quietly leaves unpriced — is visible
-- rather than only implied.
--
-- `units`, `binding` and `unpriced_types` are jsonb: a dwelling count keyed by
-- CMHC bedroom class, the printed caps the answer is pressed against (more
-- than one can bind at once — see `urban_rag.program.solve_program`'s own
-- docstring for what each name means), and the bedroom classes CMHC published
-- no rent for this borough. `program_assumptions` is every stated assumption
-- the model was run with — stalls per dwelling, the cost and rent per square
-- foot, storey heights, the amortisation horizon — so a row can always be read
-- back against the building it assumed, the rule silver.lot_frontage.buffer_m
-- and gold.lot_profiles.max_built_area_m2 both follow.
--
-- No `-- requires:` header: this table names nothing outside its own schema,
-- so it lands on the first `db.py init`. The asset that fills it has no
-- schedule of its own yet, because its own inputs — silver.
-- lot_zoning_envelopes and silver.lot_buildable_setbacks — do not either; see
-- hbu_dataplatform's `urban_rag.definitions` for the ordering once they do.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.lot_development_programs (
    -- The partition key leads, in the order 003_warehouse.sql explains.
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- The same grain as silver.lot_zoning_envelopes: one row per (lot,
    -- zone, grid column). lot_uid rather than lot_number for the reason that
    -- table gives — it is the cadastre's own surrogate key, and a candidate
    -- with no lot_number (a parcel the roll never named) is still a candidate.
    lot_uid      bigint NOT NULL,
    feature_id   text NOT NULL,
    column_index integer NOT NULL,

    -- -- the candidate, carried from lot_zoning_envelopes -------------------
    --
    -- Restated rather than left to a join, so a reader of this table alone
    -- knows what was solved. lot_number is nullable, unlike lot_uid: it is the
    -- roll's, and a parcel a zone reaches but the roll never named has none.
    lot_number   text,
    -- The zoning layer this column's grid came from — more than one can carry
    -- a grid, and is why silver.zoning_grid_columns keys on it too.
    source_table text,
    grid_zone    text,
    -- What share of the lot this zone covers. A boundary sliver and the
    -- interior of a zone both get a program; whether the sliver *governs* the
    -- lot is gold.lot_highest_best_use's question, not this table's.
    pct_of_lot   double precision,
    -- The usage codes the column is headed by, as printed — a JSON array, the
    -- same string silver.zoning_grid_columns.usages carries.
    usages       jsonb,
    permits_commercial boolean,
    permits_industrial boolean,
    -- Whether this is the column select_residential_column would pick for a
    -- lot of this width, carried from lot_zoning_envelopes.governs_residential
    -- unchanged. gold.lot_highest_best_use filters on this column, not on the
    -- income the program earns — see that table's header for why.
    governs_residential boolean,
    lot_area_m2         double precision,
    primary_frontage_m  double precision,
    -- What this column's own four margins leave buildable, from
    -- silver.lot_buildable_setbacks at the same (lot, zone, column). NULL
    -- where that asset had not run when this one solved — the footprint was
    -- then capped on Taux d'implantation alone, which is visible in `binding`
    -- naming 'site_coverage_max' rather than 'setbacks'.
    buildable_area_m2   double precision,

    -- -- whether it solved, and why not -------------------------------------
    --
    -- CP-SAT's own status name ('OPTIMAL', 'FEASIBLE', 'INFEASIBLE',
    -- 'UNKNOWN') or 'ERROR' for a model that could not be built at all.
    status       text NOT NULL,
    solved       boolean NOT NULL DEFAULT false,
    solve_error  text,

    -- -- the money, monthly (the objective's own unit) and annual -----------
    monthly_net_operating_income_cad double precision,
    annual_net_operating_income_cad  double precision,
    monthly_gross_revenue_cad        double precision,
    annual_gross_revenue_cad         double precision,

    -- -- the mix ---------------------------------------------------------
    --
    -- Dwellings by CMHC bedroom class, {"studio": 2, "1_bedroom": 9, ...} —
    -- absent keys are classes the solver declined to build, not zeros.
    units             jsonb,
    num_dwellings     integer NOT NULL DEFAULT 0,
    -- Storeys above grade, all four kinds together — the number En etage is
    -- tested against.
    floors            integer NOT NULL DEFAULT 0,
    height_m          double precision NOT NULL DEFAULT 0,
    -- Shared by every storey type — see urban_rag.program's module docstring
    -- for why one footprint and identical floors is the model's own
    -- assumption about the building.
    footprint_m2      double precision NOT NULL DEFAULT 0,
    -- footprint_m2 * (residential_floors + above_grade_parking_floors +
    -- commercial_floors + industrial_floors) — the superficie de plancher
    -- Densite is tested against. Underground is not in it; see
    -- underground_area_m2 below.
    gross_floor_area_m2   double precision NOT NULL DEFAULT 0,
    -- footprint_m2 * residential_floors — the plate, not the unit schedule.
    -- The like-for-like comparison against a roll's floor area; see the
    -- header.
    residential_area_m2   double precision NOT NULL DEFAULT 0,
    -- The narrower rentable schedule (UNIT_AREAS_SQFT) the revenue was priced
    -- from. At most residential_area_m2.
    unit_area_m2          double precision NOT NULL DEFAULT 0,
    commercial_area_m2    double precision NOT NULL DEFAULT 0,
    industrial_area_m2    double precision NOT NULL DEFAULT 0,
    -- footprint_m2 * underground_levels. Built and paid for, and outside both
    -- gross_floor_area_m2 and the storey count — article 38 1° of by-law
    -- 01-283, applied in solve_program and restated here as a fact about the
    -- row rather than something a reader has to know the by-law to see.
    underground_area_m2   double precision NOT NULL DEFAULT 0,
    -- garage_stalls * the bay allowance in program_assumptions. Inside
    -- gross_floor_area_m2, unlike underground_area_m2 beside it — which is the
    -- whole difference between parking in the ground floor and under it.
    garage_area_m2        double precision NOT NULL DEFAULT 0,
    residential_floors           integer NOT NULL DEFAULT 0,
    commercial_floors            integer NOT NULL DEFAULT 0,
    industrial_floors            integer NOT NULL DEFAULT 0,
    above_grade_parking_floors   integer NOT NULL DEFAULT 0,
    underground_levels           integer NOT NULL DEFAULT 0,
    underground_stalls           integer NOT NULL DEFAULT 0,
    above_grade_stalls           integer NOT NULL DEFAULT 0,
    -- Stalls standing on the yard the footprint leaves. Neither a storey nor
    -- superficie de plancher, because they are not in a building at all —
    -- what Taux d'implantation caps is the plate, and the rest of the parcel
    -- is ground. They are in total_stalls and in parking_cost_cad, and they
    -- are deliberately absent from floor_stack, which is a stack of storeys.
    surface_stalls               integer NOT NULL DEFAULT 0,
    -- Enclosed bays inside the building's own ground floor. Unlike every other
    -- stall here this one IS superficie de plancher: it is inside
    -- gross_floor_area_m2, the density cap counts it, and Taux d'implantation
    -- counts the plate it sits under — but it is not a storey, so En etage
    -- does not. garage_area_m2 is how much floor it took from the dwellings.
    garage_stalls                integer NOT NULL DEFAULT 0,
    total_stalls                 integer NOT NULL DEFAULT 0,

    -- -- what it costs to build, in dollars (capital, not amortised) --------
    construction_cost_cad  double precision NOT NULL DEFAULT 0,
    commercial_cost_cad    double precision NOT NULL DEFAULT 0,
    industrial_cost_cad    double precision NOT NULL DEFAULT 0,
    parking_cost_cad       double precision NOT NULL DEFAULT 0,
    total_capital_cost_cad double precision NOT NULL DEFAULT 0,

    -- -- why the answer is what it is -----------------------------------
    --
    -- The printed caps the mix is pressed against — a JSON array of names
    -- like ["density_max", "commercial_floor_area"] — and the CMHC bedroom
    -- classes this borough's survey published no rent for, so the solver
    -- would not build them. See urban_rag.program.solve_program's own
    -- docstring for what each binding name means.
    binding         jsonb NOT NULL DEFAULT '[]'::jsonb,
    unpriced_types  jsonb NOT NULL DEFAULT '[]'::jsonb,

    -- Every stated assumption the model ran with: stalls per dwelling and per
    -- 1000 sqft, the three costs per square foot, the amortisation horizon,
    -- the two non-residential rents and vacancies, and the four storey
    -- heights. '{}' is a partition written before this column existed.
    program_assumptions jsonb NOT NULL DEFAULT '{}'::jsonb,

    loaded_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, lot_uid, feature_id, column_index)
) PARTITION BY LIST (neighborhood);

-- "Every candidate on this lot" — the read gold.lot_highest_best_use exists to
-- spare a caller, and the one this table is for when that spared read is not
-- enough: "why not the other column".
CREATE INDEX IF NOT EXISTS lot_development_programs_lot_idx
    ON silver.lot_development_programs (lot_uid);
-- "The governing candidates that solved" — the pool gold.lot_highest_best_use
-- is chosen from, and the filter a reader re-deriving that choice starts from.
CREATE INDEX IF NOT EXISTS lot_development_programs_governing_idx
    ON silver.lot_development_programs (lot_uid)
    WHERE governs_residential AND solved;
-- "Every borough-wide model that ran out of time" — num_not_optimal on the
-- asset's own metadata, indexed so the handful can be found rather than only
-- counted.
CREATE INDEX IF NOT EXISTS lot_development_programs_status_idx
    ON silver.lot_development_programs (status)
    WHERE status NOT IN ('OPTIMAL', 'INFEASIBLE');

-- The discounted objective and the family flags, added when the solver
-- stopped maximising a monthly NOI and started maximising discounted net
-- profit over every priced usage family — see hbu_dataplatform's
-- `urban_rag.program.InvestmentAssumptions`. `npv_cad` is the objective: the
-- stabilised NOI discounted over the hold plus the discounted sale, less the
-- capital. `present_value_cad` is that value before the capital comes off,
-- and `annual_stabilised_noi_cad` the income figure the discounting was
-- applied to. The monthly columns above survive unchanged, restated from the
-- chosen program rather than maximised. The governs_* pair beside
-- governs_residential carries which column rules each family for this lot,
-- and permits_residential completes the permits trio for a table that now
-- holds pure C and I candidates too.
ALTER TABLE silver.lot_development_programs
    ADD COLUMN IF NOT EXISTS npv_cad double precision,
    ADD COLUMN IF NOT EXISTS present_value_cad double precision,
    ADD COLUMN IF NOT EXISTS annual_stabilised_noi_cad double precision,
    ADD COLUMN IF NOT EXISTS permits_residential boolean,
    ADD COLUMN IF NOT EXISTS governs_commercial boolean,
    ADD COLUMN IF NOT EXISTS governs_industrial boolean;

-- "The most valuable programs in the borough", on the objective's own unit.
CREATE INDEX IF NOT EXISTS lot_development_programs_npv_idx
    ON silver.lot_development_programs (npv_cad DESC)
    WHERE solved;

-- What stands on each storey, added when the question after "nine storeys and
-- forty dwellings" turned out to be "on which floor". A jsonb array of runs of
-- identical levels rather than one entry per level — the model builds one
-- plate and repeats it, so a fifteen-storey tower over retail and a parking
-- deck is four entries and not fifteen. Written by hbu_dataplatform's
-- `urban_rag.program.floor_stack`, which is also where the order the uses are
-- stacked in is written down as the reporting convention it is: the *Niveaux
-- de bâtiment autorisés* block is marked per column and not per usage, so the
-- solver counts storeys by type and never places one. Every number here is a
-- column above it re-cut by level; changing the order changes a drawing and
-- never an answer.
--
-- Entries run bottom upwards and all carry the same keys, so unnesting one
-- needs no branch on the use:
--
--   use                    parking | commercial | industrial | residential
--   position               above_grade | below_grade
--   from_level, to_level   inclusive; 1 is the rez-de-chaussée and the dug
--                          levels are -1 downwards. There is no level 0
--   floors                 levels the run spans
--   floor_plate_m2         the footprint, which every storey shares
--   floor_area_m2          floor_plate_m2 × floors
--   counts_as_floor_area   false below grade — article 38 1° of 01-283 keeps
--                          a dug level out of the superficie de plancher
--   storey_height_m        by use, and 0 below grade: height is measured from
--                          grade up, so a dug level stands no metres
--   height_m               storey_height_m × floors
--   stalls                 0 off a parking run
--   dwellings, units       0 and {} off the residential run. The mix sits on
--                          that run whole rather than divided by its storeys —
--                          the solver chose a mix for the building and not for
--                          a plate, and splitting it would invent the part it
--                          did not choose
--
-- "Every program that puts commerce at grade", which is the read the column
-- exists for:
--
--   SELECT lot_uid
--     FROM silver.lot_development_programs,
--          LATERAL jsonb_array_elements(floor_stack) AS storey
--    WHERE storey->>'use' = 'commercial'
--      AND (storey->>'from_level')::int = 1;
--
-- NOT NULL like binding beside it: every row of this table carries a program
-- row, solved or not, and an unsolved one stacks nothing.
ALTER TABLE silver.lot_development_programs
    ADD COLUMN IF NOT EXISTS floor_stack jsonb NOT NULL DEFAULT '[]'::jsonb;

-- The third place a stall can go, added when it turned out the solver had only
-- ever known the two that cost a storey or a hole: a parkade stall is $60 300
-- or $48 125 and a stall on the yard is $6 105, so on any parcel with ground
-- to spare the structured pair was pricing parking seven to ten times over
-- what gets built. Where that bit hardest was the low-density end — a grid printing H.1,
-- En etage 1/1 and Taux d'implantation 35 % permits one dwelling on one
-- storey, so no second dwelling shares the stall and the single permitted
-- storey is the dwelling's own. That left digging as the only provision, one
-- dwelling does not earn back a parkade stall, and the optimum became to build
-- nothing: parcels zoned for a house came back as 0 m² and 0 dwellings.
--
-- 0 on a partition written before the column existed, which is also the honest
-- value there — those solves had no surface option to exercise.
ALTER TABLE silver.lot_development_programs
    ADD COLUMN IF NOT EXISTS surface_stalls integer NOT NULL DEFAULT 0;

-- The fourth place, added with the third: a closed garage in the ground floor.
-- It is the one provision that is inside the building without being a storey of
-- it, so it answers to Densite and to Taux d'implantation and not to En etage,
-- and what it really costs is the floor area it takes from the dwellings —
-- which is why garage_area_m2 travels beside the count. Priced at a garage
-- shell rather than at a parkade: the Altus guide has no rate for a bay in a
-- house, and charging one a $48 125 parkade stall for a garage door is how a
-- bungalow stops penciling.
--
-- 0 on a partition written before the columns existed, which is also the honest
-- value there — those solves had no garage to build.
ALTER TABLE silver.lot_development_programs
    ADD COLUMN IF NOT EXISTS garage_stalls integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS garage_area_m2 double precision NOT NULL DEFAULT 0;

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
        'ALTER TABLE silver.lot_development_programs OWNER TO %I', app_role
    );

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON silver.lot_development_programs TO %I', ro_role
        );
    END IF;
END
$$;
