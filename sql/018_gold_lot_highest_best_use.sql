-- gold.lot_highest_best_use — the highest and best use of every piece of
-- ground in a borough. One row per (lot, zone).
--
-- Downstream of silver.lot_development_programs (sql/017), silver.
-- lot_zoning_envelopes (sql/012) and silver.lot_zone_pieces (sql/025), and the
-- answer they exist to produce: every piece of every lot a zone reaches, with
-- the program of that zone's *governing* envelope named beside it. Written by
-- hbu_dataplatform's `lot_highest_best_use` asset — see that repo's
-- `urban_rag.hbu.select_highest_best_use`.
--
-- ---------------------------------------------------------------------------
-- Why the key is (lot, zone) and not lot
-- ---------------------------------------------------------------------------
--
-- Because a zoning boundary does not have to follow a lot line, and on a large
-- parcel it usually does not.
--
-- This table used to hold one row per lot. A parcel two zones covered was
-- treated as one site with two competing readings, and the best-covered zone
-- won: `pct_of_lot` decided, the other zone's rows were dropped before
-- anything was solved, and the winner's grid was then priced over the *whole*
-- parcel. That is right for the case it was written for — a lot on a boundary
-- picking up a sliver of its neighbour's zoning because two publishers drew
-- two lines — and wrong for the case it could not tell apart from it.
--
-- Lot 1 740 794 in Villeray-Saint-Michel-Parc-Extension: 27 044 m², of which
-- 24 596 sit in H04-072 (H.7, eight storeys) and 2 440 in C04-083 (C.4 and H,
-- six). Two sites. They face two different streets — the commercial strip has
-- the 19.8 m of Jarry and the housing behind it 15.2 m of D'Hérelle — and the
-- old answer priced eight storeys over all 27 044 m² while never pricing the
-- C.4 at all. Over that borough it is 1 861 split lots and 121 ha of land
-- answered under a grid that does not govern it.
--
-- So both are solved, each over its own ground, against its own street, under
-- its own margins, and each keeps its own row. The slivers do not come back
-- with them: silver.lot_zone_pieces applies the same two cutoffs before
-- writing a piece at all, so the few square centimetres of residential zone at
-- the corner of Parc Jarry never reach a solver.
--
-- **What that means for reading this table.** `lot_number` groups the pieces
-- back into a parcel. `is_primary_zone` marks the largest, which is the row a
-- reader wanting one answer per lot takes and the answer this table used to
-- give. `num_lot_zones > 1` is the set where one row is not the whole story.
-- A borough total sums every row; a per-lot join filters `is_primary_zone`, or
-- aggregates — anything that does neither will multiply the split parcels.
--
-- ---------------------------------------------------------------------------
-- What "governing" means, and what it is not
-- ---------------------------------------------------------------------------
--
-- Within one zone and one usage family, a grid authorises the family in more
-- than one column and distinguishes them by *Largeur du terrain min* — the
-- column a piece of this width is written for is `select_governing_column`'s
-- pick, carried through as `governs_residential` / `governs_commercial` /
-- `governs_industrial` on sql/012 and sql/017.
--
-- **Across families the choice is real, and it is priced.** A zone writing an
-- H.2 column and a C.4 column beside it authorises either building, and which
-- to put up is exactly the highest-and-best-use question. The chosen row is:
-- among the governing columns of this piece's zone, the program worth the most
-- discounted net profit (`npv_cad`), column index breaking a tie. The
-- maximisation over the *mix* is still inside `solve_program`; what is
-- maximised here is which governing envelope — the developer's use decision.
-- Picking a non-governing column of the same family would still report a
-- building under rules the parcel may not be built to, and is still never
-- done; every candidate that lost keeps its row in
-- silver.lot_development_programs, which is where "why not the other column"
-- is answered. `hbu_dominant_use` says in one word what kind of building won:
-- residential, commercial, industrial, mixed, or none.
--
-- Nothing is maximised *across* pieces any more. Which of a parcel's pieces is
-- worth more is a question for whoever sorts a shortlist, not one this table
-- answers by deleting a row.
--
-- **Every piece the envelopes reach keeps a row.** A piece whose every column
-- authorises commerce and not housing has no program at all, and `hbu_status`
-- says why rather than leaving a null row to be misread as a gap in the data:
--
--   solved                a governing envelope was solved
--   no_candidate_column   every envelope on this piece authorises none of the
--                         usages the solver prices — Habitation, Commerce or
--                         Industrie. Équipements collectifs is deliberately
--                         not a proforma; pure C and I zones solve like
--                         everything else now and no longer land here
--   equipment_zone        the narrower reading of the same absence: this
--                         piece's grid authorises Équipements collectifs, so
--                         it is a park or a school rather than a grid that
--                         failed to parse. Per piece, which is what lets a
--                         parcel that is half park and half housing say both
--   no_governing_column   candidate columns exist and none governs — almost
--                         always ground with no measured frontage under a
--                         grid stating a width minimum, which reads as 0 m
--                         and qualifies for nothing. On a split lot an
--                         interior piece behind a street-facing one genuinely
--                         fronts nothing, so this is an answer as often as it
--                         is a gap
--   infeasible            a governing column was solved and none has a
--                         feasible program — a minimum the parcel cannot
--                         meet. Stalls it has nowhere to put no longer land
--                         here on their own: such a piece is solved again
--                         without them, reported solved, and carries
--                         parking_waived with the stalls it owes beside it
--   solver_error          a governing column could not be turned into a
--                         model at all; see the program row's own
--                         solve_error on sql/017
--
-- (`no_residential_column` is this table's former name for the first of
-- those, from when the solver priced dwellings alone; rows written before
-- the rename keep it until their partition is re-materialized.)
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
    -- The zone, and the second half of the key. One row per (lot, zone) — one
    -- per *piece* of ground — because a zoning boundary crossing a large
    -- parcel makes two sites of it, and both are solved. See the header.
    feature_id   text NOT NULL,
    lot_number   text,

    -- -- the ground this row is about ---------------------------------------
    --
    -- `lot_area_m2` is the parcel; `piece_area_m2` is the ground this zone
    -- governs and is what the program below was solved over. Equal wherever
    -- one zone covers a lot whole, which is most of a borough.
    lot_area_m2   double precision,
    piece_area_m2 double precision,
    pct_of_lot    double precision,
    -- How many pieces the parcel has, where this one ranks by area, and
    -- whether it is the largest. A reader wanting one row per lot filters
    -- `is_primary_zone`; a reader summing a borough must not, or the split
    -- parcels are counted once instead of whole.
    num_lot_zones   integer,
    zone_rank       integer,
    is_primary_zone boolean,

    -- -- what the piece faces, and what stands on it ------------------------
    --
    -- The street *this piece* fronts on, re-ranked inside it rather than
    -- inherited from the lot: on a split parcel a commercial strip and the
    -- housing behind it face different streets.
    primary_frontage_m    double precision,
    primary_street_name   text,
    secondary_frontage_m  double precision,
    secondary_street_name text,
    num_frontages         integer,
    -- The footprint measured on this piece, and the two shares
    -- gold.lot_redevelopment_gap divides the lot's assessment by. Both sum to
    -- 1 across a lot's pieces; see sql/025 for why there are two.
    existing_footprint_m2 double precision,
    area_share            double precision,
    footprint_share       double precision,
    footprint_share_basis text,

    -- -- how much of a choice this piece actually had ---------------------
    --
    -- Candidates counted, not envelope rows: a piece under a grid with one
    -- Habitation column and three Commerce ones had one choice, and
    -- num_candidates says 1, not 4.
    num_candidates            integer NOT NULL DEFAULT 0,
    num_governing_candidates  integer NOT NULL DEFAULT 0,
    -- The zones of the *lot*, so the same number on each of its pieces — the
    -- reader's cue that this row is one of several. Duplicates num_lot_zones
    -- above and predates it; both are kept because the older readers filter on
    -- this one.
    num_zones                 integer NOT NULL DEFAULT 0,
    -- One of the five values the header lists.
    hbu_status  text NOT NULL,

    -- -- the governing envelope, when there is one -----------------------
    source_table  text,
    column_index  integer,
    grid_zone     text,
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
    garage_area_m2        double precision,
    residential_floors           integer,
    commercial_floors            integer,
    industrial_floors            integer,
    underground_levels           integer,
    underground_stalls           integer,
    -- On the yard rather than in the building. See sql/017.
    surface_stalls               integer,
    -- In the ground floor rather than on a storey of its own. See sql/017.
    garage_stalls                integer,
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
    -- The zone is in the key. One row per piece of ground, not per parcel:
    -- see the header, and gold.lot_redevelopment_gap and the three tables
    -- below it, which all follow this key for the same reason.
    PRIMARY KEY (scrape_date, neighborhood, lot_uid, feature_id)
) PARTITION BY LIST (neighborhood);

-- "How many lots are answered, and how many of each unanswered kind" — the
-- GROUP BY hbu_status the header promises, indexed so it does not have to
-- scan the whole borough for it.
CREATE INDEX IF NOT EXISTS lot_highest_best_use_status_idx
    ON gold.lot_highest_best_use (hbu_status);
-- The two indexes over `is_primary_zone` and `num_lot_zones` are created in
-- sql/025 rather than here, and the reason is the order these files run in.
-- `CREATE TABLE IF NOT EXISTS` above does nothing on a database that already
-- holds this table, so on such a database those columns do not exist until
-- 025's migration adds them — and an index over a column that is not there
-- yet fails the file, and with it the rest of the init. 025 adds the columns
-- and the indexes together, which works on a fresh database and on an
-- existing one alike. See "Re-keying the tables downstream" there.
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

-- The discounted objective, the family flags and the one-word verdict —
-- added with the solver's move to discounted net profit; see sql/017's own
-- ALTER block for what the money columns mean.
ALTER TABLE gold.lot_highest_best_use
    ADD COLUMN IF NOT EXISTS npv_cad double precision,
    ADD COLUMN IF NOT EXISTS present_value_cad double precision,
    ADD COLUMN IF NOT EXISTS annual_stabilised_noi_cad double precision,
    ADD COLUMN IF NOT EXISTS permits_residential boolean,
    ADD COLUMN IF NOT EXISTS governs_residential boolean,
    ADD COLUMN IF NOT EXISTS governs_commercial boolean,
    ADD COLUMN IF NOT EXISTS governs_industrial boolean,
    ADD COLUMN IF NOT EXISTS hbu_dominant_use text;

-- "The most valuable lots in the borough", on the unit the choice was made in.
CREATE INDEX IF NOT EXISTS lot_highest_best_use_npv_idx
    ON gold.lot_highest_best_use (npv_cad DESC)
    WHERE solved;
-- "Every lot whose highest use is commerce (or industry, or mixed)" — the
-- read the dominant-use word exists for.
CREATE INDEX IF NOT EXISTS lot_highest_best_use_dominant_use_idx
    ON gold.lot_highest_best_use (hbu_dominant_use)
    WHERE solved;

-- What stands on each storey of the chosen program — silver.
-- lot_development_programs' own column (sql/017), restated on the winning row
-- like every money and mix column above it. That header is where the shape of
-- an entry is, and where the order the uses are stacked in is written down as
-- the reporting convention it is rather than something the solver decided.
--
-- Nullable here and NOT NULL there, and the difference is this table's whole
-- posture: a lot whose every envelope authorises commerce keeps its row and
-- has no program at all, and an empty array would read as "a building with no
-- storeys" where the honest value is "no building was chosen". hbu_status
-- says which of the two a null is.
ALTER TABLE gold.lot_highest_best_use
    ADD COLUMN IF NOT EXISTS floor_stack jsonb;

-- Carried up from sql/017 with the rest of the chosen program. Nullable here
-- and NOT NULL there for the same reason floor_stack is: a lot with no program
-- has no stall count either, and 0 would read as "parks nothing" where the
-- honest value is "nothing was chosen".
ALTER TABLE gold.lot_highest_best_use
    ADD COLUMN IF NOT EXISTS surface_stalls integer,
    ADD COLUMN IF NOT EXISTS garage_stalls integer,
    ADD COLUMN IF NOT EXISTS garage_area_m2 double precision;

-- The ground the surface stalls take, and the shape of the ground there was to
-- take it from — see sql/017, which states both at length.
--
-- surface_area_m2 is nullable here and NOT NULL there for the reason every
-- carried program column is: a lot with no program reserved no yard, and 0
-- would read as "parks nothing on the ground" where the honest value is
-- "nothing was chosen". It is the number gold.lot_building_massing draws a
-- rectangle of, so it is carried up rather than recomputed from the stall
-- count — a caller who moved the per-stall allowance would otherwise have the
-- drawing and the solve disagree.
--
-- parkable_area_m2 belongs to the *parcel* rather than to the chosen envelope,
-- so unlike its neighbours it is on every row, including the lots with no
-- program at all. A lot reporting 0 here is one no car can stand on, whatever
-- else is true of it.
ALTER TABLE gold.lot_highest_best_use
    ADD COLUMN IF NOT EXISTS surface_area_m2 double precision,
    ADD COLUMN IF NOT EXISTS parkable_area_m2 double precision;

-- placeable_area_m2 is the counterpart of buildable_area_m2 above and belongs
-- to the chosen *envelope* rather than to the parcel, so it sits beside it and
-- is null on the rows with no program: the largest rectangle that fits inside
-- that column's margins, which is the third cap on footprint_m2 and the ground
-- surface_area_m2 is rationed against (lot_area_m2 less this, charged whole).
-- See sql/017 for why an area cap alone was not enough, and lot 6 744 583 for
-- what it cost. Read beside buildable_area_m2 it is the answer to "why is this
-- plate so much smaller than the envelope": the margins leave the area and the
-- envelope's shape does not hold a building of it.
ALTER TABLE gold.lot_highest_best_use
    ADD COLUMN IF NOT EXISTS placeable_area_m2 double precision;

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
ALTER TABLE gold.lot_highest_best_use
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

-- ---------------------------------------------------------------------------
-- Widening: the gross income split by the family that earns it
-- ---------------------------------------------------------------------------
--
-- The chosen program's side of sql/017's widening of the same name, which is
-- where the argument is written out in full. In short: a building's income is
-- not divided the way its floor is, because commerce earns several times what
-- housing does per square foot, and the cellar plates are rented at a discount
-- and stand outside commercial_area_m2 — so the split has to be carried.
--
-- The three sum to annual_gross_revenue_cad less the parking rent beside them
-- (annual_parking_gross_revenue_cad). gold.lot_redevelopment_gap nets
-- them into hbu_residential_noi_cad and its two neighbours, and
-- hbu_dataplatform's `urban_rag.proforma` blends a cap rate over those.
ALTER TABLE gold.lot_highest_best_use
    ADD COLUMN IF NOT EXISTS annual_residential_gross_revenue_cad double precision,
    ADD COLUMN IF NOT EXISTS annual_commercial_gross_revenue_cad  double precision,
    ADD COLUMN IF NOT EXISTS annual_industrial_gross_revenue_cad  double precision;

-- ---------------------------------------------------------------------------
-- Widening: the parking waived
-- ---------------------------------------------------------------------------
--
-- The chosen program's side of sql/017's widening of the same name, which is
-- where the argument is written out. In short: a piece whose stalls alone made
-- every governing program infeasible used to report hbu_status = 'infeasible'
-- and nothing else; it now reports 'solved' with the program the envelope
-- holds, parking_waived = true, and waived_stalls saying how many stalls that
-- program owes at program_assumptions' ratios and does not provide. Every
-- stall column on such a row is 0 because nothing was provided, not because
-- nothing was owed - which is the whole reason the flag travels with them.
--
-- Nullable here and NOT NULL there for the reason every carried program column
-- is: a piece with no program at all waived nothing, and false would read as
-- "solved with its parking" where the honest value is "nothing was chosen".
ALTER TABLE gold.lot_highest_best_use
    ADD COLUMN IF NOT EXISTS parking_waived boolean,
    ADD COLUMN IF NOT EXISTS waived_stalls  integer;

-- "Every chosen programme standing on a parking variance" - what the Deal pane
-- warns about per lot, counted over a borough.
CREATE INDEX IF NOT EXISTS lot_highest_best_use_parking_waived_idx
    ON gold.lot_highest_best_use (lot_uid)
    WHERE parking_waived;

-- ---------------------------------------------------------------------------
-- Widening: what the parking earns
-- ---------------------------------------------------------------------------
--
-- The chosen program's side of sql/017's widening of the same name, which
-- states the rule. The stalls somebody rents and their rent a year (inside
-- annual_gross_revenue_cad, so the three family lines sum to the gross less
-- it), the coverage in stalls per dwelling, the lease-up months that coverage
-- saves the housing, and the present value of the saving (inside
-- present_value_cad and npv_cad, in no NOI). Nullable here, like every carried
-- program column: a piece with no program rents nothing, and 0 would read as
-- "nothing rented" where the honest value is "nothing was chosen".
ALTER TABLE gold.lot_highest_best_use
    ADD COLUMN IF NOT EXISTS rented_stalls                    integer,
    ADD COLUMN IF NOT EXISTS annual_parking_gross_revenue_cad double precision,
    ADD COLUMN IF NOT EXISTS parking_coverage                 double precision,
    ADD COLUMN IF NOT EXISTS lease_up_months_saved            double precision,
    ADD COLUMN IF NOT EXISTS absorption_value_cad             double precision;

-- ---------------------------------------------------------------------------
-- Widening: three provisions, and the hole is the parcel's
-- ---------------------------------------------------------------------------
--
-- The chosen program's side of sql/017's widening of the same name, which
-- states the rule: the above-grade deck is no longer a provision and its two
-- columns are dropped, and the dug parking sits on a plate of its own -
-- underground_plate_m2, bounded by the parcel rather than by footprint_m2 -
-- so underground_area_m2 is the stalls' own area and no longer the footprint
-- times the levels. Nullable here, like every carried program column.
ALTER TABLE gold.lot_highest_best_use
    ADD COLUMN IF NOT EXISTS underground_plate_m2 double precision,
    DROP COLUMN IF EXISTS above_grade_parking_floors,
    DROP COLUMN IF EXISTS above_grade_stalls;
