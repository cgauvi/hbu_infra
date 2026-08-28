-- silver.lot_assessed_values — what every lot in a borough is assessed at,
-- from Quebec's rôle d'évaluation foncière.
--
-- Infolot draws the lot and says nothing about its worth; the roll values the
-- property and draws no lot. Nothing published joins the two, so
-- hbu_dataplatform's `lot_assessed_values` asset computes it: each assessment
-- unit's point is placed in the lot it falls inside, and the units on a lot
-- are summed. See that repo's `urban_rag.role_assets`.
--
-- `lot_number` is Infolot's own NO_LOT — "2 170 935" for a numbered lot,
-- "PC-29987" for the common parts of a divided co-ownership — and is the
-- natural key this table's upsert conflicts on: one lot, one borough, one day,
-- one row.
--
-- `total_assessed_value` is the sum of rl0404a (VALEUR IMMEUBLE: land plus
-- buildings, as entered on the roll in force) over the units on the lot.
-- **Nullable on purpose.** A lot with no assessment unit on it — a lane, a
-- park, a city parcel — keeps its row with `num_assessment_units = 0` and a
-- NULL total, because a sum over nothing is not a value of zero, and a reader
-- that averaged $0 across the borough's lanes would be answering a different
-- question than the one it asked.
--
-- `num_assessment_units` is not decoration. A divided-co-ownership building is
-- one unit per apartment, all of them on the one PC-* common-parts lot: 402
-- units and $258M on a single lot in the first VSMPE snapshot. The total only
-- means what a reader thinks it means with the count beside it.
--
-- `numeric` rather than `double precision` for the total: these are dollars
-- summed over hundreds of rows, and a borough's roll runs to $27 billion.
--
-- `roll_year` travels on every row because the roll is triennial and the
-- pipeline's date axis is the *scrape* date, not the roll's. Two scrape dates
-- three months apart carry the same 2026 roll; two a year apart may not, and
-- nothing else in the row would say so.
--
-- `attributes` keeps everything else Infolot publishes about the lot — area,
-- status, last edit — unchanged. Same posture as silver.neighborhood_streets
-- and rag.features: the source adds and retires columns between releases, and
-- a schema needing a migration each time is a schema that will not survive.

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.lot_assessed_values (
    scrape_date          date NOT NULL,
    neighborhood         text NOT NULL,
    -- NO_LOT in the published cadastre.
    lot_number           text NOT NULL,
    -- Assessment units whose point falls inside this lot. 0 is a real answer.
    num_assessment_units integer NOT NULL DEFAULT 0,
    -- Sum of rl0404a over those units. NULL when there are none — see above.
    total_assessed_value numeric,
    -- Fiscal year of the roll the values came from, not the scrape date.
    roll_year            integer,
    attributes           jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- EPSG:4326, matching every other geometry here. The lot polygon as
    -- Infolot drew it, with its self-intersecting rings repaired upstream —
    -- Unconstrained `Geometry` rather than MultiPolygon, like the other silver
    -- join tables: ST_MakeValid answers a Polygon, a MultiPolygon or a
    -- GeometryCollection depending on what it had to repair, and a narrower
    -- type would reject exactly the rows that needed repairing.
    geom                 geometry(Geometry, 4326),
    loaded_at            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, lot_number)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS lot_assessed_values_geom_idx
    ON silver.lot_assessed_values USING gist (geom);
-- The read this table exists for: the most valuable ground in a borough, and
-- the lots carrying nothing. Partial, because the NULLs are the other question
-- and a full index would carry every lane in the city to answer neither.
CREATE INDEX IF NOT EXISTS lot_assessed_values_total_idx
    ON silver.lot_assessed_values (total_assessed_value DESC)
    WHERE total_assessed_value IS NOT NULL;

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
        'ALTER TABLE silver.lot_assessed_values OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON silver.lot_assessed_values TO %I', ro_role);
    END IF;
END
$$;
