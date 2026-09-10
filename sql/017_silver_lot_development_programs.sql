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
    -- The parcel, and the ground this zone governs — from
    -- silver.lot_zone_pieces (sql/025). `piece_area_m2` is what the program
    -- below was solved over; `lot_area_m2` is the lot it is a piece of, and on
    -- a parcel a zoning boundary crosses the two are different numbers. Equal
    -- on the great majority of rows, where one zone covers a lot whole.
    lot_area_m2         double precision,
    piece_area_m2       double precision,
    num_lot_zones       integer,
    is_primary_zone     boolean,
    -- The street *that piece* faces, re-ranked inside it rather than inherited
    -- from the lot: on a split parcel a commercial strip and the housing
    -- behind it front different streets, and it is this width the grid's
    -- *Largeur du terrain min* was tested against.
    primary_frontage_m  double precision,
    primary_street_name text,
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
    -- footprint_m2 * (residential_floors + commercial_floors +
    -- industrial_floors) — the superficie de plancher
    -- ABOVE GRADE, and the number a massing extrudes. It is no longer the
    -- whole of what Densite is tested against: a cellar of usage is floor area
    -- too, so that cap answers to density_floor_area_m2 = this plus
    -- basement_area_m2 — both added at the foot of this file, where the
    -- distinction is written out. Underground *parking* is in neither; see
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
    -- The dug parking: underground_stalls times the stall allowance in
    -- program_assumptions, spread over underground_levels at
    -- underground_plate_m2 a level (added at the foot of this file). Built
    -- and paid for, and outside gross_floor_area_m2, the storey count AND the
    -- footprint — articles 38 1° and 43 of by-law 01-283, applied in
    -- solve_program and restated here as a fact about the row rather than
    -- something a reader has to know the by-law to see. It used to be
    -- footprint_m2 * underground_levels; the plate is now the parcel's.
    underground_area_m2   double precision NOT NULL DEFAULT 0,
    -- garage_stalls * the bay allowance in program_assumptions. Inside
    -- gross_floor_area_m2, unlike underground_area_m2 beside it — which is the
    -- whole difference between parking in the ground floor and under it.
    garage_area_m2        double precision NOT NULL DEFAULT 0,
    residential_floors           integer NOT NULL DEFAULT 0,
    commercial_floors            integer NOT NULL DEFAULT 0,
    industrial_floors            integer NOT NULL DEFAULT 0,
    underground_levels           integer NOT NULL DEFAULT 0,
    underground_stalls           integer NOT NULL DEFAULT 0,
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
-- plate and repeats it, so a fifteen-storey tower over retail is two entries
-- and not fifteen. Written by hbu_dataplatform's
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
--   use                    parking | commercial | industrial | residential;
--                          parking only ever below grade — no storey is a
--                          parking deck, the bays ride on the residential run
--   position               above_grade | below_grade
--   from_level, to_level   inclusive; 1 is the rez-de-chaussée and the dug
--                          levels are -1 downwards. There is no level 0
--   floors                 levels the run spans
--   floor_plate_m2         the footprint, which every storey shares — except
--                          the below-grade parking run, whose plate is
--                          underground_plate_m2: the parcel's, not the
--                          building's, and it may be the wider
--   floor_area_m2          floor_plate_m2 × floors
--   counts_as_floor_area   false below grade — article 38 1° of 01-283 keeps
--                          a dug level out of the superficie de plancher
--   storey_height_m        by use, and 0 below grade: height is measured from
--                          grade up, so a dug level stands no metres
--   height_m               storey_height_m × floors
--   stalls                 the dug stalls on the below-grade parking run, the
--                          garage bays on the residential run, 0 elsewhere
--   parking_area_m2        the floor those stalls take: the whole of a dug
--                          run, garage_area_m2 on the residential run (inside
--                          its floor_area_m2 — the ground floor is that much
--                          garage), 0 elsewhere
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

-- The ground those surface stalls actually take, and the shape of the ground
-- there was to take it from. Added together because they are two halves of the
-- same correction.
--
-- surface_area_m2 is what the model reserved on the yard — stall count times
-- the 300 sq ft allowance, at the hundredth of a square metre the solver holds
-- areas to. It is floor area of no kind: not in gross_floor_area_m2, not in
-- footprint_m2, and not under the building the way underground_area_m2 is.
-- That is the whole of what a surface stall is, and it is why
-- gold.lot_surface_parking (sql/024) draws it as a polygon of its own instead
-- of the massing folding it in.
--
-- parkable_area_m2 is the ground measured rather than the program solved: the
-- yard opened by half a stall's depth — 5.5 m in article 566 of by-law 01-283
-- — so what is left is ground with that much clear in every direction. It is
-- an input to the solve and not an output of it, and it exists because the
-- constraint it stands beside is an area against an area.
-- `surface_stall_area × stalls + footprint <= lot area` is satisfied on a
-- parcel two metres wide, where no car stands in any orientation, so the
-- cheapest stall in the model was being spent on land that cannot take it —
-- and being cheapest, it was spent first and everywhere.
--
-- It was the largest parking-shaped *rectangle* of the bare *parcel*, and both
-- halves of that were wrong. The parcel, because there was no building to
-- subtract until placeable_area_m2 below fixed the plate before the solve —
-- so every yard was overstated by whatever the building would go on to cover.
-- A rectangle, because the shape a yard actually has is a band wrapping the
-- building, and no rectangle covers a ring: across 600 real VSMPE yards the
-- rectangle read a median 34 pct of the ground where the opening reads 79.
-- It is now measured on `parcel less the placeable rectangle`, by the same
-- function gold.lot_surface_parking (sql/024) uses to draw the polygon — so
-- the bound and the drawing are one rule, and surface_parking_fit_pct is a
-- check that can pass rather than the 51.7 pct two searches produced.
--
-- Both are measured off the cadastre in Python (urban_rag.massing), so a
-- partition whose run could not reach rag.lots has parkable_area_m2 NULL and
-- its stalls bounded on area alone, which is what every run did before this.
-- NULL is "nobody measured"; 0 is "measured, and no car stands here".
-- binding names surface_parking_shape on the rows where the shape is what
-- stopped the surface stalls.
ALTER TABLE silver.lot_development_programs
    ADD COLUMN IF NOT EXISTS surface_area_m2 double precision NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS parkable_area_m2 double precision;

-- The sous-sol, added when the solver stopped treating everything below grade
-- as parking. Article 38 1 of by-law 01-283 excludes *une aire de
-- stationnement des vehicules [...] situee en sous-sol, de meme que leurs
-- voies d'acces* from the superficie de plancher and excludes nothing else, so
-- a below-grade level of dwellings or of shops is floor area the density index
-- counts, while the parkade under it is not. Both are below grade; only one is
-- charged, and that is the whole of the distinction these columns carry.
--
-- What Densite is tested against is therefore density_floor_area_m2 =
-- gross_floor_area_m2 + basement_area_m2, and NOT gross_floor_area_m2 alone
-- any more. That column keeps its old meaning exactly - footprint_m2 times the
-- storeys above grade - because it is what a massing extrudes and what
-- gold.lot_building_massing measures its placed area against; the cap moved to
-- the wider column beside it rather than into it.
--
-- Neither storey cap sees any of this. En etage counts a building's storeys
-- and a below-grade level is not one; Hauteur en metre is measured from grade
-- up. So floors and height_m are unchanged by a cellar, and
-- basement_*_levels are counted apart from them. Nor is the footprint: the
-- basement is modelled flat under the building above it - one plate, the same
-- plate - so Taux d'implantation has nothing further to say about it.
--
-- basement_dwellings is the part of num_dwellings that stands in the cellar.
-- It is counted separately because it is priced separately: dearer to build by
-- program_assumptions ->> 'below_grade_cost_premium' and leased under the
-- storeys above it by 'below_grade_rent_discount_pct'. That is the one place
-- the solver says which level a dwelling is on, and it says it because the two
-- rates differ.
--
-- 'basement_levels_allowed' in program_assumptions is how many below-grade
-- levels of usage the run permitted where a column's *Niveaux de batiment
-- autorises* rows authorise any - a modelling bound like max_underground_levels
-- beside it, not a norm the grid prints. binding names 'basement_levels' where
-- the cellar is spent and 'basement_unbuilt' where the level rows allow one
-- and the arithmetic declined to build it.
--
-- **Which rows authorise one is not the same question for the three
-- families.** A dwelling goes below grade only where the grid names the level
-- - the *Inferieurs au RDC* row, marked on 91 of Villeray's 1 555 columns.
-- Commerce and industry go there under that row or under *Tous les niveaux*,
-- on the reading that a column confining a shop to no floor in particular has
-- not excluded the floor beneath it: a stock room under a store is the same
-- usage as the store, and somebody's home is not. So
-- basement_commercial_area_m2 and basement_industrial_area_m2 turn up across
-- the borough and basement_residential_area_m2 only where the grid spelled the
-- cellar out - and, at the rates in program_assumptions, hardly even there:
-- the premium and the discount together put a sous-sol dwelling just under
-- water at every class CMHC prices.
ALTER TABLE silver.lot_development_programs
    ADD COLUMN IF NOT EXISTS density_floor_area_m2 double precision,
    ADD COLUMN IF NOT EXISTS basement_area_m2 double precision,
    ADD COLUMN IF NOT EXISTS basement_residential_area_m2 double precision,
    ADD COLUMN IF NOT EXISTS basement_commercial_area_m2 double precision,
    ADD COLUMN IF NOT EXISTS basement_industrial_area_m2 double precision,
    ADD COLUMN IF NOT EXISTS basement_levels integer,
    ADD COLUMN IF NOT EXISTS basement_residential_levels integer,
    ADD COLUMN IF NOT EXISTS basement_commercial_levels integer,
    ADD COLUMN IF NOT EXISTS basement_industrial_levels integer,
    ADD COLUMN IF NOT EXISTS basement_dwellings integer;

-- placeable_area_m2 is the envelope measured rather than the program solved,
-- and it is to buildable_area_m2 what parkable_area_m2 above is to the yard:
-- an area is not a footprint. Taux d'implantation au sol says what share of
-- the parcel may be covered and the four margins say where on it, and both are
-- areas — so both are satisfied by a plate no rectangle of the envelope could
-- ever be. An 8 886 m² envelope shaped like a skewed parallelogram holds no
-- building above about 5 519 m², and until this column existed the solver
-- priced the 8 886: gold.lot_building_massing then shrank the plate to fit and
-- reported footprint_fit_pct, by which point the dwellings, the NOI and the
-- npv_cad had all been computed on ground the parcel never had.
--
-- So this is the largest rectangle that actually fits inside that column's
-- margins — the same search, at the same settings, that the massing asset uses
-- to draw the building — and it is a third ceiling on footprint_m2 beside the
-- coverage and the margins. Per (lot, zone, column) rather than per lot, since
-- the margins that carve it are printed in a zoning column.
--
-- It also rations the yard: the ground a surface stall may stand on is
-- lot_area_m2 − placeable_area_m2, the whole rectangle charged whether or not
-- the answer fills it. Deliberately independent of footprint_m2 — the
-- footprint is a decision, and one the solver would otherwise shrink purely to
-- buy cheap stalls, handing the unbuilt part of its own rectangle to the
-- parking as if a building could be trimmed to a shape that leaves a parking
-- lot behind. Lot 6 744 583 is what that cost: a 7 045 m² plate and 2 369 m²
-- of asphalt on a 9 415 m² parcel, satisfying every inequality in the model
-- with 0.89 m² to spare, describing no site anyone could build.
--
-- Measured in Python (urban_rag.massing.placeable_area_m2), so a partition
-- written before the setbacks geoparquet existed has it NULL and its footprint
-- capped on the two area norms alone, which is what every run did before this.
-- NULL is "nobody measured"; 0 is "measured, and these margins hold no
-- building". binding names placement where the shape rather than either
-- printed norm capped the plate, and yard_full where the site ran out of
-- ground for one more stall.
ALTER TABLE silver.lot_development_programs
    ADD COLUMN IF NOT EXISTS placeable_area_m2 double precision;

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

-- ---------------------------------------------------------------------------
-- Widening: the gross income split by the family that earns it
-- ---------------------------------------------------------------------------
--
-- annual_gross_revenue_cad is one number over a building that can hold three
-- kinds of space, and the three do not earn alike. At the rates in
-- program_assumptions a square foot of commerce collects about four times what
-- a square foot of housing does, so the storey at grade of a high-street
-- building is a sixth of its floor and very nearly half its rent. Every
-- question downstream that weights a lot by use — a cap rate blended to what
-- the building actually earns, a lease-up measured per family, a thesis — wants
-- the income split and not the floor split, and the floor split is all the
-- {residential,commercial,industrial}_area_m2 columns above can give.
--
-- Carried rather than derived for a second reason: each of these includes its
-- own below-grade plate, rented at below_grade_rent_discount_pct under the
-- storey above it. commercial_area_m2 is the plate *En etage* counts and
-- basement_commercial_area_m2 is beside it, so no arithmetic on the area
-- columns reproduces what the cellar earns.
--
-- The three sum to annual_gross_revenue_cad less the parking rent beside them
-- (annual_parking_gross_revenue_cad, further down). NULL on a partition
-- written before they existed, where the honest answer is that the split was
-- never computed — unlike the garage columns above, zero would be a lie here.
ALTER TABLE silver.lot_development_programs
    ADD COLUMN IF NOT EXISTS annual_residential_gross_revenue_cad double precision,
    ADD COLUMN IF NOT EXISTS annual_commercial_gross_revenue_cad  double precision,
    ADD COLUMN IF NOT EXISTS annual_industrial_gross_revenue_cad  double precision;

-- ---------------------------------------------------------------------------
-- Widening: the parking waived
-- ---------------------------------------------------------------------------
--
-- A candidate the stalls alone make infeasible used to keep an INFEASIBLE row
-- and nothing else, and the piece it governs reported hbu_status =
-- 'infeasible' on sql/018 - the same word a coverage minimum the parcel cannot
-- meet gets, and a far less useful one, because the parcel *does* hold a
-- building; it holds no parking for it. `urban_rag.program.solve_program` now
-- asks the second question itself where the first was answered INFEASIBLE by
-- CP-SAT (and never for the named contradictions in binding, which are two
-- printed rows disagreeing): the model is solved again with both stall ratios
-- at zero, and a program that solves without the stalls was stopped by the
-- stalls and by nothing else.
--
--   parking_waived   true on exactly those rows. status is then CP-SAT's
--                    status on the *second* solve - OPTIMAL, ordinarily - and
--                    every stall column is 0 because nothing was provided,
--                    not because nothing was owed.
--   waived_stalls    what the program owes at the ratios in
--                    program_assumptions, rounded up once in aggregate: the
--                    size of the variance the row is standing on. 0 wherever
--                    parking_waived is false.
--
-- A model still infeasible without its parking keeps the plain INFEASIBLE it
-- always had, so the status counts on sql/018 lose only the rows that never
-- belonged in them. 'waive_parking_if_infeasible' in program_assumptions is
-- the switch, and a row written under false reports what it always did.
--
-- NOT NULL with defaults, like every count on this table: a row written before
-- the column existed was solved with its parking and provided what it owed.
ALTER TABLE silver.lot_development_programs
    ADD COLUMN IF NOT EXISTS parking_waived boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS waived_stalls  integer NOT NULL DEFAULT 0;

-- "Every programme standing on a parking variance" - the read the widening is
-- for. Partial, because the steady state is that almost no row is.
CREATE INDEX IF NOT EXISTS lot_development_programs_parking_waived_idx
    ON silver.lot_development_programs (lot_uid)
    WHERE parking_waived;

-- ---------------------------------------------------------------------------
-- Widening: what the parking earns
-- ---------------------------------------------------------------------------
--
-- A stall was a pure cost to the objective until program_assumptions carried
-- parking_stall_rent_cad_month and parking_stall_occupancy_pct: it earned
-- nothing, so the solver built exactly what it owed and never one more. It now
-- earns its rent on the stalls the occupants would rent - at most
-- market_stalls_per_dwelling per dwelling and market_stalls_per_1000_sqft per
-- thousand square feet of shop or workshop, which is what stops the yard being
-- paved for tenants who do not exist - through the same present-value
-- multiplier a dwelling's rent goes through, and it may be built beyond what
-- is owed where that pays. Parking also leases the housing faster:
-- parking_absorption_saving_months of lease-up at a full stall per dwelling,
-- concave in the coverage below it, priced as the present value the shorter
-- lease-up adds to the dwellings' rent.
--
--   rented_stalls                     the stalls that earn: at most
--                                     total_stalls, at most the market's
--   annual_parking_gross_revenue_cad  their rent a year at the stated take-up,
--                                     INSIDE annual_gross_revenue_cad - so the
--                                     three family lines above sum to the gross
--                                     less this, not to the gross
--   parking_coverage                  total_stalls over num_dwellings
--   lease_up_months_saved             what that coverage saves the housing
--   absorption_value_cad              the present value of the saving, inside
--                                     present_value_cad and npv_cad and in no
--                                     NOI - a timing effect, not income
--
-- rented_stalls is NOT NULL with a default like every count here; the money
-- columns are NULL on a partition written before they existed, where the
-- honest answer is that no stall was priced.
ALTER TABLE silver.lot_development_programs
    ADD COLUMN IF NOT EXISTS rented_stalls                    integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS annual_parking_gross_revenue_cad double precision,
    ADD COLUMN IF NOT EXISTS parking_coverage                 double precision,
    ADD COLUMN IF NOT EXISTS lease_up_months_saved            double precision,
    ADD COLUMN IF NOT EXISTS absorption_value_cad             double precision;

-- ---------------------------------------------------------------------------
-- Widening: three provisions, and the hole is the parcel's
-- ---------------------------------------------------------------------------
--
-- The solver now knows three places to put a stall and not four: on the yard
-- (surface_stalls), in the ground floor (garage_stalls) and under the parcel
-- (underground_stalls). The above-grade parking deck - a whole storey of
-- stalls, priced at the guide's parkade_ag rate - is gone: a deck is a storey
-- En etage counts and floor area Densite counts both, it was never what got
-- built on a Villeray lot, and every program that used to deck now bays or
-- digs. Its two columns are dropped rather than left at zero, so a reader
-- cannot take an always-zero count for a finding.
--
-- And the hole is no longer the plate. underground_area_m2 used to be
-- footprint_m2 * underground_levels - the parkade confined to the building
-- above it - which on a narrow lot priced digging out of reach. Article 43 of
-- 01-283 excludes *une partie du batiment qui est entierement sous terre* from
-- the site coverage, so a dug level may run out under the yard to the lot
-- line, and it now does: the plate of a dug level is bounded by
-- program_assumptions ->> 'underground_lot_share' of lot_area_m2 (1.0 by
-- default) and by nothing about the building. underground_area_m2 is the area
-- the stalls actually took - the stall allowance times underground_stalls -
-- and underground_plate_m2 is that over underground_levels, which the model
-- pins to the fewest levels that hold it. It may exceed footprint_m2, and on a
-- small house it usually does: one wide level rather than three deep ones.
--
-- floor_stack carries the same two facts: the below-grade parking run's
-- floor_plate_m2 is underground_plate_m2, and every entry now has
-- parking_area_m2 - the whole of a dug run, garage_area_m2 on the residential
-- run, 0 elsewhere - so the ground floor that is two bays of garage reads as
-- exactly that rather than as two storeys of housing with stalls attached.
--
-- 0 on a partition written before the column existed; re-solve to fill it.
ALTER TABLE silver.lot_development_programs
    ADD COLUMN IF NOT EXISTS underground_plate_m2 double precision NOT NULL DEFAULT 0,
    DROP COLUMN IF EXISTS above_grade_parking_floors,
    DROP COLUMN IF EXISTS above_grade_stalls;
