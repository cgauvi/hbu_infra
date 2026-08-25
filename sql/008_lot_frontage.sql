-- The lot x street join: how much of each parcel's edge faces each street
-- side, in metres.
--
-- requires: rag.streets
--
-- Frontage is what a highest-and-best-use question turns on after area. Two
-- 400 m2 lots side by side are not the same site if one has 30 m on a
-- boulevard and the other 6 m on a lane — the width of the street edge decides
-- what can be built, how it is entered, and what it is worth. Neither
-- publisher records it: Infolot draws the parcel, the géobase double draws the
-- sides of the roadway, and what connects them is geometry.
--
-- Computed by hbu_dataplatform (urban_rag.postgis.compute_lot_frontage) once
-- that borough's rag.lots and rag.streets rows have landed — see its README.
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
-- rag.lot_profiles.max_built_area_m2 carries its threshold.
--
-- `frontage_rank` is 1 for the longest frontage a lot has, and is the column to
-- filter on when a question wants *the* street a lot fronts on rather than
-- every street it touches. A corner lot legitimately has two; a lot clipping a
-- side street by 40 cm has a second one that is a survey artifact.
--
-- Refreshed the way the other derived joins are: a (neighborhood, scrape_date)
-- partition is deleted and reinserted, not upserted row by row.
--
-- Owned by the same role as the rest of `rag`, handed over below.

SET search_path TO rag, public;

CREATE TABLE IF NOT EXISTS rag.lot_frontage (
    lot_frontage_uid bigserial PRIMARY KEY,
    lot_uid          bigint NOT NULL REFERENCES rag.lots (lot_uid) ON DELETE CASCADE,
    street_uid       bigint NOT NULL REFERENCES rag.streets (street_uid) ON DELETE CASCADE,
    -- Denormalised from rag.streets: the *_uid columns are bigserials a reload
    -- mints again, and these two are what survives one.
    cote_rue_id      text NOT NULL,
    street_name      text,
    neighborhood     text NOT NULL,
    scrape_date      date NOT NULL,
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
    UNIQUE (lot_uid, street_uid)
);

CREATE INDEX IF NOT EXISTS lot_frontage_geom_idx ON rag.lot_frontage USING gist (geom);
CREATE INDEX IF NOT EXISTS lot_frontage_lot_idx ON rag.lot_frontage (lot_uid);
-- "The widest lots in this borough, longest first" is the read this table
-- exists for, so it gets an index rather than a sort.
CREATE INDEX IF NOT EXISTS lot_frontage_partition_idx
    ON rag.lot_frontage (neighborhood, scrape_date, frontage_m DESC);
-- "The primary frontage of every lot" — frontage_rank = 1 — is the other.
CREATE INDEX IF NOT EXISTS lot_frontage_primary_idx
    ON rag.lot_frontage (neighborhood, scrape_date)
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

    EXECUTE format('ALTER TABLE rag.lot_frontage OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON rag.lot_frontage TO %I', ro_role);
    END IF;
END
$$;
