-- silver.lot_frontage — the lot x street join: how much of each parcel's edge
-- faces each street side, in metres.
--
-- requires: silver.neighborhood_streets
--
-- Frontage is what a highest-and-best-use question turns on after area. Two
-- 400 m2 lots side by side are not the same site if one has 30 m on a
-- boulevard and the other 6 m on a lane — the width of the street edge decides
-- what can be built, how it is entered, and what it is worth. Neither
-- publisher records it: Infolot draws the parcel, the géobase double draws the
-- sides of the roadway, and what connects them is geometry.
--
-- Computed by hbu_dataplatform (urban_rag.postgis.compute_lot_frontage) once
-- that borough's rag.lots and silver.neighborhood_streets rows have landed,
-- and written through urban_rag.warehouse — see 003_warehouse.sql.
--
-- Two things about the measure are worth knowing before reading a number here.
--
-- First, it is taken on the lot's ST_Boundary, not on the lot. The direct
-- reading of the question —
--
--     ST_Length(ST_Intersection(lot.geom, street_buffer.geom))
--
-- — intersects two polygons, gets a polygon, and ST_Length of a polygon is 0
-- in PostGIS: every row would report no frontage at all. Frontage is a length
-- along the parcel's edge, so the left-hand side has to be the boundary.
--
-- Second, `buffer_m`. A lot line does not sit on the curb line — there is a
-- sidewalk between them, and the city publishes the géobase "à titre
-- indicatif" rather than to survey accuracy — so the street side is buffered
-- before the boundary is clipped to it. Widening that buffer costs accuracy at
-- the corners: the first `buffer_m` of each *side* boundary falls inside it
-- too and is counted as frontage. The value used is written onto every row so
-- a table can always be read back against its own cutoff, the same way
-- gold.lot_profiles.max_built_area_m2 carries its threshold.
--
-- `frontage_rank` is 1 for the longest frontage a lot has, and is the column to
-- filter on when a question wants *the* street a lot fronts on rather than
-- every street it touches. A corner lot legitimately has two; a lot clipping a
-- side street by 40 cm has a second one that is a survey artifact.
--
-- Moved here from rag.lot_frontage. Besides the partition key leading the
-- primary key, one thing changed: `street_uid` is gone, and with it the
-- foreign key on it. Its parent is now partitioned, where a primary key has to
-- contain the partition keys — so silver.neighborhood_streets could not keep a
-- bigserial one, and a foreign key has nothing left to reference. Neither is a
-- loss: `cote_rue_id` is the publisher's own key for a street side, it is what
-- this table already denormalised because the serial did not survive a reload,
-- and the pairing is enforced by the partition instead. Both tables are keyed
-- on (scrape_date, neighborhood, …) and the join that fills this one runs
-- inside a single partition of both. The old table is left in place; drop it
-- once nothing reads it:
--
--     DROP TABLE IF EXISTS rag.lot_frontage;

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.lot_frontage (
    scrape_date      date NOT NULL,
    neighborhood     text NOT NULL,
    lot_uid          bigint NOT NULL
        REFERENCES rag.lots (lot_uid) ON DELETE CASCADE,
    -- The publisher's own key for a street side, and the half of this row's
    -- key that survives a reload — which is why it, and not street_uid, is in
    -- the primary key.
    cote_rue_id      text NOT NULL,
    lot_number       text,
    street_name      text,
    -- How far from the street side a lot boundary counted as facing it. See
    -- the header: the numbers below mean nothing without it.
    buffer_m         double precision NOT NULL,
    frontage_m       double precision NOT NULL,
    lot_perimeter_m  double precision NOT NULL,
    -- 100 * frontage_m / lot_perimeter_m — how much of the parcel's edge this
    -- particular street accounts for.
    pct_of_perimeter double precision NOT NULL,
    -- 1 for this lot's longest frontage, 2 for its next, ...
    frontage_rank    integer NOT NULL,
    -- The facing stretch of boundary itself, not the whole lot edge and not
    -- the street. Left as a bare Geometry rather than typed MultiLineString:
    -- ST_CollectionExtract returns a MultiLineString, but a future clip that
    -- keeps more than linework should not need a migration to land.
    geom             geometry(Geometry, 4326),
    loaded_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, lot_uid, cote_rue_id)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS lot_frontage_geom_idx
    ON silver.lot_frontage USING gist (geom);
CREATE INDEX IF NOT EXISTS lot_frontage_lot_idx
    ON silver.lot_frontage (lot_uid);
CREATE INDEX IF NOT EXISTS lot_frontage_lot_number_idx
    ON silver.lot_frontage (lot_number);
-- "The widest lots in this borough, longest first" is the read this table
-- exists for, so it gets an index rather than a sort. The partition already
-- narrows to the borough-month, so the index only has to carry the ordering.
CREATE INDEX IF NOT EXISTS lot_frontage_longest_idx
    ON silver.lot_frontage (frontage_m DESC);
-- "The primary frontage of every lot" — frontage_rank = 1 — is the other.
CREATE INDEX IF NOT EXISTS lot_frontage_primary_idx
    ON silver.lot_frontage (lot_uid)
    WHERE frontage_rank = 1;

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

    EXECUTE format('ALTER TABLE silver.lot_frontage OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON silver.lot_frontage TO %I', ro_role);
    END IF;
END
$$;
