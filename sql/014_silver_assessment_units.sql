-- silver.assessment_units — every assessed property in a borough, as the
-- province describes it.
--
-- One row per *unité d'évaluation* from Quebec's rôle d'évaluation foncière:
-- the point the roll places it at, and the characteristics it is described by
-- — assessed values, land and floor area, storeys, year built, dwellings, use
-- code. hbu_dataplatform's `assessment_units` asset merges the roll's point
-- layer (`rol_unite_p`) and its characteristics table (`b05v_unite_evaln`) on
-- `id_provinc`, which is what the publisher splits them by and what this table
-- keys a row on.
--
-- This is the row-level record `silver.lot_assessed_values` aggregates. That
-- table answers "what is this lot worth"; this one answers "what is on it, and
-- what kind of thing is it" — the questions a highest-and-best-use model asks
-- before it asks about value. Neither is derivable from the other: the totals
-- there are sums over the units here, and the units carry the use code, the
-- floor area and the year built that no total keeps.
--
-- ---------------------------------------------------------------------------
-- The borough is read off the map, not off the roll
-- ---------------------------------------------------------------------------
--
-- The roll has no borough axis. It is published once for the province, and the
-- asset that merges it is partitioned by date alone — so unlike every other
-- table in this schema, one materialization fills *several* of this table's
-- partitions, through urban_rag.warehouse.publish_by_neighborhood.
--
-- The `neighborhood` a row lands in is the borough whose reference_neighbor-
-- hoods outline the unit's point falls inside. That is the same cut
-- silver.neighborhood_streets makes on the island-wide geobase double — one
-- publication, cut into partitions in silver — made against points instead of
-- lines.
--
-- The roll does state a borough of its own, and it is kept in `arrond` rather
-- than partitioned on: REM25 is no_arr 25, which is VSMPE. Two agencies
-- answering one question, and geometry is what the rest of this platform cuts
-- on, so geometry decides here too. The pipeline reports
-- `num_units_arrond_disagrees` per run so the choice stays visible; a
-- partition where that stops being 0 is a boundary that moved.
--
-- **The tree and this table do not hold the same rows, on purpose.** The
-- parquet under silver/assessment_units/ carries every municipality the run's
-- `municipality_codes` kept — the whole province with CODE_MUN='[]' — and this
-- table carries the boroughs. `num_units_outside_every_borough` is the
-- difference, and it is a count rather than an error: Westmount and Laval file
-- rolls too, and are not boroughs.
--
-- ---------------------------------------------------------------------------
-- Named columns, and the forty that are not
-- ---------------------------------------------------------------------------
--
-- The roll names its fields by MAMH code — rl0404a, rl0308a. The ones this
-- platform reads are given a name here and mapped in
-- urban_rag.warehouse.TABLES; the rest land in `attributes` unchanged, where a
-- reader who knows the code can still reach them and a roll that adds a field
-- needs no migration. Same posture as silver.lot_assessed_values and
-- rag.features.
--
-- `land_value` + `building_value` = `assessed_value` exactly, on all 437,192
-- Montreal units of the 2026 roll: rl0402a and rl0403a are the halves of
-- rl0404a (VALEUR IMMEUBLE), not independent estimates. `numeric` for all
-- three, because these are dollars and the largest single unit on the island
-- is assessed at $2.27 billion.
--
-- An assessed value is a value for taxation on the roll in force, not a market
-- appraisal, and Montreal's roll is triennial — every unit in a 2026 roll is
-- valued as of one reference date. `roll_year` travels on every row because
-- the pipeline's date axis is the *scrape* date: two scrape dates three months
-- apart carry the same roll, two a year apart may not, and nothing else in the
-- row would say so.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.assessment_units (
    scrape_date  date NOT NULL,
    -- The borough the point fell in. See the header: assigned from geometry,
    -- not from `arrond` below.
    neighborhood text NOT NULL,
    -- The municipality's five-digit geographic code followed by the
    -- 18-character matricule. What every table in the archive is keyed on, and
    -- what a re-run of a partition conflicts on.
    id_provinc   text NOT NULL,
    code_mun     text,
    mat18        text,
    -- The roll's own borough: REM + no_arr. Kept as a cross-check, never
    -- partitioned on.
    arrond       text,
    -- rl0105a, the CUBF use code — four digits, 1000 (residential) to 9900.
    -- Text and not integer: it is a classification, and its leading digit is
    -- the category rather than a magnitude.
    use_code     text,
    -- rl0301a, mesure frontale. Null for a unit with no frontage of its own,
    -- which is every apartment in a divided co-ownership.
    frontage_m   double precision,
    -- rl0302a, superficie du terrain.
    land_area_m2 double precision,
    -- rl0306a, nombre d'étages.
    num_storeys  integer,
    -- rl0307a, année de construction. Published as four characters; an integer
    -- and not a date, which would claim a day and a month the roll never says.
    year_built   integer,
    -- rl0308a, aire d'étages.
    floor_area_m2 double precision,
    -- rl0311a. A divided co-ownership is one unit per apartment, so this is
    -- the dwellings in *this* unit, not in the building it stands in.
    num_dwellings integer,
    -- rl0312a, locaux non résidentiels.
    num_nonresidential_units integer,
    -- rl0313a, chambres locatives.
    num_rental_rooms integer,
    -- rl0402a and rl0403a: the land and building halves of the value below.
    land_value     numeric,
    building_value numeric,
    -- rl0404a, VALEUR IMMEUBLE — land plus buildings, on the roll in force.
    assessed_value numeric,
    -- Fiscal year of the roll the values came from, not the scrape date.
    roll_year    integer,
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- EPSG:4326, matching every other geometry here. The roll publishes this
    -- layer as MULTIPOINT in EPSG:4269 and the pipeline reprojects; the type
    -- stays unconstrained `Geometry` like the other silver tables, so whether
    -- the reader hands back a Point or a singleton MultiPoint is a driver
    -- detail rather than a rejected row.
    geom         geometry(Geometry, 4326),
    loaded_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, id_provinc)
) PARTITION BY LIST (neighborhood);

-- Point-in-polygon against the cadastre, which is what places a unit on a lot
-- when the roll's own lot-number crosswalk cannot.
CREATE INDEX IF NOT EXISTS assessment_units_geom_idx
    ON silver.assessment_units USING gist (geom);
-- The read this table exists for alongside the lot totals: the most valuable
-- properties in a borough. Partial, for the reason sql/013 gives — a unit with
-- no value on the roll is the other question.
CREATE INDEX IF NOT EXISTS assessment_units_value_idx
    ON silver.assessment_units (assessed_value DESC)
    WHERE assessed_value IS NOT NULL;
-- "Every triplex in the borough", "everything built before 1950" — the filter
-- a typology question starts from, and one the primary key does not serve.
CREATE INDEX IF NOT EXISTS assessment_units_use_code_idx
    ON silver.assessment_units (use_code);

DO $$
DECLARE
    app_role text := 'urban_rag';
    ro_role  text := 'urban_rag_ro';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
        RAISE NOTICE
            'role % does not exist — apply 000_roles.sql, then re-run this '
            'file to hand over ownership', app_role;
        RETURN;
    END IF;

    EXECUTE format(
        'ALTER TABLE silver.assessment_units OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON silver.assessment_units TO %I', ro_role);
    END IF;
END
$$;
