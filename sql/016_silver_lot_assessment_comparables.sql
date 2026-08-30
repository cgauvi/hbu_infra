-- silver.lot_assessment_comparables — what every lot in a borough yields, and
-- which lots the roll says are like it.
--
-- The same grain and the same key as silver.lot_assessed_values (sql/013),
-- because it is the same lot. That table sums one column of Quebec's rôle
-- d'évaluation foncière — rl0404a, VALEUR IMMEUBLE — over the assessment units
-- standing on each parcel, and stops, because a total is what it is for. This
-- one is the two questions a reader asks next:
--
--   Is that a lot of money for this lot?   → cap_rate_pct
--   What is it worth, if not what the roll says?  → estimated_value_cad
--
-- Two tables rather than more columns on one. A reader who wants only "what is
-- this lot assessed at" should not have to read a jsonb of neighbours to get
-- it, and the totals over there are a measurement where everything here rests
-- on a stated assumption or two. Written by hbu_dataplatform's
-- `lot_assessment_comparables` asset — see that repo's `urban_rag.comparables`,
-- where every judgement below is written down.
--
-- ---------------------------------------------------------------------------
-- The income side, and what is measured in it
-- ---------------------------------------------------------------------------
--
-- A cap rate is income over value and the roll publishes only the value. The
-- income is built from what the roll says stands on the parcel — the dwellings
-- and the floor area, the latter split into three classes by each unit's own
-- CUBF use code (rl0105a) rather than by a dominant use for the lot, so a
-- triplex over a dépanneur earns both.
--
-- Exactly two of the inputs are measured:
--
--   * the dwellings and the floor area, from the roll;
--   * the rent and the vacancy, from CMHC's survey of this borough.
--
-- Everything else is stated, and `income_assumptions` carries all of it on
-- every row so a rate can always be read back against what produced it — the
-- rule silver.lot_frontage.buffer_m and gold.lot_profiles.max_built_area_m2
-- follow. The commercial and industrial rates per square foot come from
-- hbu_dataplatform's `urban_rag.program`, which is also what the development
-- solver prices a new building's floors at, so the two cannot drift apart.
-- `operating_expense_ratio` is the single largest lever on every rate in this
-- table.
--
-- **Vacancy is netted per class and the expense ratio once at the end.** They
-- are different things — income never collected against collected income that
-- leaves again — and applying either to the other's result would charge one of
-- them twice.
--
-- **Null, not zero, where a class was not priced.** A borough CMHC suppressed
-- the rent for has a null residential income however many dwellings stand in
-- it, and `gross_income_cad` is null only when *no* class could be priced —
-- which is the difference between a lot that earns nothing and a lot nobody
-- could price. A lane with neither dwellings nor floor is the first.
--
-- **The characteristics are counted whole, and that is what makes the ratio
-- safe.** A unit spanning several lots contributes its dwellings and its floor
-- to each of them, exactly as it contributes its whole value to each in
-- lot_assessed_values.total_assessed_value. That over-counts a borough on both
-- sides of the fraction and therefore cancels in the quotient: a shared triplex
-- makes both lots report the yield of a triplex. `cap_rate_pct` is not a column
-- to SUM() in any case; the apportioned total in sql/013 is the one that adds
-- up across lots.
--
-- **An assessed value is not a market value.** Quebec's roll is triennial and
-- every unit in it is valued as of one reference date; the province publishes a
-- *facteur comparatif* to carry a roll figure to a market one, and it is not in
-- this publication. `income_assumptions ->> 'market_value_factor'` is what was
-- applied — 1.0 by default, which reports the yield **on the roll** and says
-- so.
--
-- ---------------------------------------------------------------------------
-- The comparables
-- ---------------------------------------------------------------------------
--
-- `comparables` holds the k lots most like this one, chosen on four things at
-- once — the CUBF use code, the parcel's area, the floor standing on it, the
-- dwellings that floor holds — and on how far away it is. One weighted distance
-- rather than a filter and a sort: each feature becomes a dimensionless
-- distance scaled by what one unit of being wrong about it is worth, and the
-- composite is the weighted Euclidean norm over them. The object carries the
-- scales, the penalties and the weights beside the neighbour list, because a
-- neighbour list means nothing without the metric that chose it.
--
-- Size is compared as a *ratio* and distance is not: twice the floor area is
-- the same difference in kind at 100 m² as at 2,000, while 300 m is 300 m
-- anywhere in the borough. The use code is categorical and scored in three
-- steps — same four digits, same CUBF class, neither — and is never read as a
-- magnitude: 1000 and 4000 are residential and commercial, not three thousand
-- apart.
--
-- **Every lot is a subject; only a valued lot is a candidate.** A lane, a park
-- or a city parcel gets a neighbour list and can never be in one, because a
-- comparable with no assessed value contributes no dollars per dwelling and no
-- dollars per square metre — which is the only thing a neighbour is consulted
-- for. That asymmetry is the point: it is what values a vacant parcel off the
-- built ones around it, through `value_per_land_m2_cad` and the ground area of
-- its own polygon.
--
-- **The pool is this borough.** sql/013 is partitioned by borough, so the
-- valued lots available as comparables are the ones in the same partition and a
-- parcel on the boundary draws its neighbours from its own side of it. A
-- limitation of how the upstream is partitioned rather than a modelling choice;
-- the asset reports `num_candidates` per run so a thin pool is visible.
--
-- `estimated_value_cad` is the median comparable ratio applied back to this
-- lot, and `estimated_value_basis` names which ratio — 'per_dwelling' where the
-- lot has dwellings, then 'per_floor_area', then 'per_land_area', which is the
-- only one a parcel carrying nothing can be valued on. Three estimates arrived
-- at three ways are not interchangeable, so the basis travels beside the
-- number rather than being inferred from what else the row has.
--
-- `assessed_to_estimated_ratio` is the two put side by side, and is the screen
-- this table exists for. Well under 1 is a parcel the roll values below what
-- its own neighbours imply — either a mispricing or a lot doing less with its
-- ground than the ones around it, and a highest-and-best-use question starts
-- from exactly that list.
--
-- ---------------------------------------------------------------------------
-- Carried, not recomputed
-- ---------------------------------------------------------------------------
--
-- `total_assessed_value` and its apportioned twin arrive from sql/013 by a join
-- on lot number and travel through untouched, so the two tables cannot disagree
-- about what a lot is worth. The unit counts *are* recomputed by the asset, as
-- a cross-check rather than as an answer — it re-derives the same (unit, lot)
-- placement that table's totals were summed over, and reports
-- `num_units_disagreeing` per run. Anything but 0 there is a stale parquet on
-- one side.
--
-- `lot_area_m2` is the **polygon's** area, projected to EPSG:32188, and not the
-- roll's own rl0302a — which is carried as `roll_land_area_m2` for reading
-- only. Two reasons, and the second is why it matters: the polygon has an area
-- for every lot including the ones no unit stands on, which is what makes the
-- land basis available to a vacant parcel; and a divided co-ownership states
-- the whole parcel's superficie on *every one* of its apartments, so summing
-- the roll's column over a 402-unit tower measures the same ground four hundred
-- times.
--
-- No `-- requires:` header: this table names nothing outside its own schema, so
-- it lands on the first `db.py init` and the asset is scheduled normally — the
-- same footing sql/013 and sql/014 are on.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.lot_assessment_comparables (
    -- The partition key leads, in the order 003_warehouse.sql explains.
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- NO_LOT in the published cadastre, and the same key sql/013 conflicts on.
    lot_number   text NOT NULL,
    -- The polygon's own area, in EPSG:32188 metres. See the header for why this
    -- and not the roll's rl0302a.
    lot_area_m2  double precision,

    -- -- carried from silver.lot_assessed_values ---------------------------
    --
    -- Untouched, so the two tables cannot disagree. The counts are that
    -- table's; `num_assessment_units` being 0 with a NULL total is a lane, and
    -- is a measurement rather than a gap.
    num_assessment_units integer NOT NULL DEFAULT 0,
    num_shared_units     integer NOT NULL DEFAULT 0,
    num_units_by_point   integer NOT NULL DEFAULT 0,
    -- Every unit's whole value, counted on each lot it covers. Right for "what
    -- is the property on this lot worth"; wrong to SUM() across a borough — use
    -- the apportioned column beside it for that, exactly as in sql/013.
    total_assessed_value numeric,
    total_assessed_value_apportioned numeric,
    -- Fiscal year of the roll, not the scrape date. The roll is triennial and
    -- this table's date axis is the cadastre's.
    roll_year    integer,

    -- -- what the roll says stands on it -----------------------------------
    --
    -- Summed over the units placed on the lot, each counted whole. NULL rather
    -- than 0 where the roll states nothing: a lot whose units carry no floor
    -- area is not a lot with no floor, and the comparable search scores the two
    -- differently.
    num_dwellings            integer,
    num_nonresidential_units integer,
    num_rental_rooms         integer,
    floor_area_m2            double precision,
    -- The same floor, split by each unit's own rl0105a. The three need not add
    -- up to floor_area_m2: a blank use code, or one outside the eight classes
    -- the *Manuel d'évaluation foncière* numbers, lands in none of them and is
    -- priced at nothing rather than at the average of a guess.
    residential_floor_area_m2 double precision,
    commercial_floor_area_m2  double precision,
    industrial_floor_area_m2  double precision,
    -- rl0302a summed over the units. Carried for reading, and NOT the lot's
    -- area — see the header. On an ordinary single-unit lot the two agreeing is
    -- worth being able to check; on a condominium's PC-* lot they will not.
    roll_land_area_m2        double precision,
    -- The use code, class and income class of the unit carrying most of the
    -- lot's value — not the largest floor and not the commonest code. The unit
    -- that is most of what the lot is worth is the one whose use a reader means
    -- when they ask what the lot *is*. Text and not integer: rl0105a is a
    -- classification whose leading digit is the category.
    dominant_use_code     text,
    dominant_use_class    text,
    dominant_income_class text,
    -- Read off that same unit, so the three describe one property rather than
    -- three different ones. year_built is an integer and not a date: the roll
    -- publishes four characters and claims no day or month.
    year_built   integer,
    num_storeys  integer,

    -- -- what it earns a year ----------------------------------------------
    --
    -- Gross of the expense ratio and net of each class's own vacancy. Null
    -- where that class could not be priced, which for the residential one is
    -- every lot in a borough CMHC suppressed.
    residential_income_cad double precision,
    commercial_income_cad  double precision,
    industrial_income_cad  double precision,
    -- The classes that were priced, added. Null only when none was.
    gross_income_cad       double precision,
    -- The same, less operating_expense_ratio. What the two rates below divide.
    net_operating_income_cad double precision,
    -- NOI over the assessed value, in percent — as a cap rate is quoted, and as
    -- vacancy_rate_pct beside it is stored. Scaled by market_value_factor if
    -- the run set one; 1.0 is the yield on the roll. NULL where either side is
    -- missing, and a lot assessed at nothing yields NULL rather than infinity.
    cap_rate_pct             double precision,
    -- The same income over what the comparables say the lot is worth. Differs
    -- from the column above by exactly assessed_to_estimated_ratio, and a lot
    -- where the two are far apart is one whose assessment and whose
    -- neighbourhood are telling different stories.
    comparable_cap_rate_pct  double precision,
    -- Every stated assumption the two rates rest on: the rent and vacancy that
    -- were surveyed, the expense ratio, the two per-square-foot rates and their
    -- vacancies, the market value factor, and the CMHC survey they came from.
    -- '{}' is a partition written before this column existed.
    income_assumptions jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- -- what the lots around it say ---------------------------------------
    --
    -- 0 is a real answer: a parcel with nothing inside the run's radius. In a
    -- borough that is a handful on the edge of an industrial strip.
    num_comparables integer NOT NULL DEFAULT 0,
    -- The composite metric, averaged, and the ground distance, median. The
    -- first says how alike the neighbours actually are — a set averaging 0.3 is
    -- four near-identical triplexes, one averaging 2.0 is the best the borough
    -- could do — and the second is the only component a reader can check
    -- against a map.
    comparable_mean_distance     double precision,
    comparable_median_distance_m double precision,
    -- The median comparable ratios. Median rather than mean for the reason
    -- every appraisal takes medians: one condominium tower's common-parts lot
    -- carrying 402 units and $258M would otherwise decide the answer on its
    -- own. Each is taken over the neighbours that *have* it, so the three can
    -- rest on three different denominators and num_comparables stands in for
    -- none of them.
    comparable_value_per_dwelling_cad double precision,
    comparable_value_per_floor_m2_cad double precision,
    comparable_value_per_land_m2_cad  double precision,
    -- The first ratio the lot can be valued on, applied back to it. numeric
    -- like the totals above, and for the same reason: these are dollars.
    estimated_value_cad   numeric,
    -- Which ratio that was: 'per_dwelling', 'per_floor_area', 'per_land_area'
    -- or 'none'. Three estimates arrived at three ways are not interchangeable,
    -- and a column that did not say which it was would be read as though they
    -- were.
    estimated_value_basis text,
    -- The screen. Under 1 is a parcel the roll values below what its own
    -- neighbours imply. NULL where either side is missing or the estimate is
    -- zero — a ratio against nothing is not a low ratio.
    assessed_to_estimated_ratio double precision,
    -- {k, max_distance_m, num_candidates, scales, penalties, weights,
    --  neighbors: [{lot_number, distance, distance_m, use_code, lot_area_m2,
    --               floor_area_m2, num_dwellings, num_assessment_units,
    --               total_assessed_value, value_per_dwelling_cad,
    --               value_per_floor_m2_cad, value_per_land_m2_cad}, ...]}
    --
    -- The metric travels with the list on purpose: '{}' is a partition whose
    -- asset has not run, and an object whose `neighbors` is empty is a lot with
    -- nothing inside the radius. Both happen, and only the first is a pipeline
    -- problem.
    comparables jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- Everything else the cadastre and this asset publish about the lot,
    -- unchanged — including the projected centroid the metric was computed on.
    -- Same posture as silver.lot_assessed_values and rag.features.
    attributes  jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- EPSG:4326, the lot polygon as sql/013 carries it. Unconstrained
    -- `Geometry` rather than MultiPolygon, like every other silver join table:
    -- ST_MakeValid upstream answers a Polygon, a MultiPolygon or a
    -- GeometryCollection depending on what it had to repair, and a narrower
    -- type would reject exactly the rows that needed repairing.
    geom        geometry(Geometry, 4326),
    loaded_at   timestamptz NOT NULL DEFAULT now(),
    -- One row per lot per borough-day, the grain sql/013 declares and the
    -- conflict target the upsert names.
    PRIMARY KEY (scrape_date, neighborhood, lot_number)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS lot_assessment_comparables_geom_idx
    ON silver.lot_assessment_comparables USING gist (geom);
-- "The best-yielding ground in the borough" — the read this table exists for.
-- Partial, for the reason sql/013's is: the NULLs are the other question (a
-- lane earns nothing and is worth nothing to a yield screen), and a full index
-- would carry every one of them to answer neither.
CREATE INDEX IF NOT EXISTS lot_assessment_comparables_cap_rate_idx
    ON silver.lot_assessment_comparables (cap_rate_pct DESC)
    WHERE cap_rate_pct IS NOT NULL;
-- The other read, and the one a highest-and-best-use question starts from:
-- ASC, because the interesting end is the *low* one — the parcels the roll
-- values furthest below what their own neighbours imply.
CREATE INDEX IF NOT EXISTS lot_assessment_comparables_ratio_idx
    ON silver.lot_assessment_comparables (assessed_to_estimated_ratio)
    WHERE assessed_to_estimated_ratio IS NOT NULL;
-- "Every triplex in the borough", "every lot with commercial floor on it" —
-- the filter a typology question starts from, and one the primary key does not
-- serve. The same index silver.assessment_units carries on its own use code.
CREATE INDEX IF NOT EXISTS lot_assessment_comparables_use_idx
    ON silver.lot_assessment_comparables (dominant_use_code);

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
        'ALTER TABLE silver.lot_assessment_comparables OWNER TO %I', app_role
    );

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON silver.lot_assessment_comparables TO %I', ro_role
        );
    END IF;
END
$$;
