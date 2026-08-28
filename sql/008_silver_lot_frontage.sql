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
-- Second, `buffer_m` — which is a *reach*, not a buffer, and rows written
-- before 2026-08 mean something else by it. It used to be exactly that: the
-- street side was buffered and the lot boundary clipped to the result. That
-- measure could not be made to work at any setting. A lot line does not sit on
-- the curb line — the géobase double is drawn along the roadway, the city
-- publishes it "à titre indicatif", and the median lot line in VSMPE sits
-- 4.85 m behind it — so at the 3 m the pipeline defaulted to, 22 545 of that
-- borough's 24 952 lots (90 %) had no row here at all. Widening
-- the buffer to reach them inflated everything it did reach: a lot's two side
-- boundaries run at the street, their first `buffer_m` falls inside the buffer
-- too, and every lot gained two metres of frontage it does not have per metre
-- of buffer. Lot 3 790 556, whose street edge measures 15.24 m, was reported
-- as 16.3 m at a 4 m buffer and 32.3 m at 12 m.
--
-- What is measured now is the lot boundary that runs *along* a street side:
-- the boundary is chopped into ~1 m pieces, each piece is matched to the
-- single nearest side within `buffer_m`, and a piece counts only if it runs
-- within 45° of parallel to that side. The result no longer moves with
-- `buffer_m` — the same lot measures 15.24 m at 6, 8, 10 and 12 — so the value
-- is free to be wide enough to reach the lots, and defaults to 10 m.
--
-- `buffer_m` still decides which lots got a row at all, so it is still written
-- onto every row, the same way gold.lot_profiles.max_built_area_m2 carries its
-- threshold. A table whose rows say 3.0 was measured the old way and is
-- missing most of its borough.
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
    -- the street — the pieces that were counted, merged back into as few
    -- linestrings as they allow, so ST_Length of this is frontage_m. Left as a
    -- bare Geometry rather than typed MultiLineString: ST_LineMerge returns a
    -- LineString for a lot whose frontage is one contiguous run and a
    -- MultiLineString for one that meets the same side twice.
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
