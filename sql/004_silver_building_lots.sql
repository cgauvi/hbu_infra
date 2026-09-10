-- silver.building_lot_intersections — the building x lot join.
--
-- requires: rag.buildings
--
-- For each footprint clipped to the lot(s) it actually falls in, one row
-- holding that slice's geometry and its share of the building's area. A
-- building spanning several lots — a school, a warehouse, an apartment tower —
-- gets one row per lot it overlaps, each carrying only the portion of the
-- footprint inside that lot; nothing here assigns the whole building to a
-- single "primary" parcel.
--
-- Computed by hbu_dataplatform (urban_rag.postgis.compute_intersections) with
-- ST_Intersection, once that borough's rag.buildings/rag.lots rows have landed,
-- and written through urban_rag.warehouse — see that module and
-- 003_warehouse.sql for the partitioning and the upsert this table's primary
-- key exists to serve.
--
-- "The lot(s) it actually falls in" is a screen, not a description, and it is
-- applied on the way in rather than left to each reader. BDOI draws a terrace
-- or a shopping strip as one contiguous outline running straight through the
-- party walls, so clipping it to the cadastre is what gives each parcel its own
-- house — and the same clip hands each parcel the few square metres of its
-- neighbour's house that fall on this side of a lot line the two surveys draw
-- differently. A party wall exactly on the line clips to a line or a point and
-- is dropped for having no dimension; a wall a hand's breadth over it clips to
-- a thin polygon that has area and is still the house next door.
-- postgis.MIN_BUILDING_OVERLAP_M2 and MIN_BUILDING_PCT_OF_BUILDING are what
-- drop the second kind, and they are an *or*: a slice is kept if it is large
-- enough to be a building, or is enough of its own footprint to be one. See
-- those constants for why that is not the *and* the zone cutoffs in
-- 005_silver_lot_features.sql use, and why the difference matters.
--
-- So this table is thresholded rather than faithful, and that is the one place
-- the two silver joins deliberately differ. A zone sliver is a real overlap
-- whose significance depends on the question, and each reader of lot_features
-- asks a different one; a sliver of the neighbour's wall is not a building on
-- this lot under any question, and no reader here wants it. hbu_rag_map applies
-- the identical cutoffs in the fallbacks it answers from before this table is
-- built (queries._BUILDING_CLIP_SCREEN), which is what keeps those rows and
-- these the same set.
--
-- Changing either cutoff means recomputing the affected partitions, since the
-- rows below the cutoff are not here to be read back at another one.
--
-- ---------------------------------------------------------------------------
-- Moved from rag.building_lots
-- ---------------------------------------------------------------------------
--
-- This is the `building_lot_intersections` asset's own table, and the asset is
-- silver, so the table is in `silver` and named for the asset rather than for
-- the join behind it. Three things changed with the move, all of them forced
-- by declarative partitioning and none of them a loss:
--
--   * `building_lot_uid bigserial PRIMARY KEY` is gone. A partitioned table's
--     primary key has to contain the partition keys, and a surrogate that no
--     reader ever cited was the wrong half to keep.
--   * the key is (scrape_date, neighborhood, building_uid, lot_uid) — the
--     grain the old UNIQUE (building_uid, lot_uid) already declared, widened
--     by the partition it was always implicitly inside.
--   * `lot_number` is carried down from rag.lots. `lot_uid` is a bigserial
--     load_lots mints again on every reload, so on its own a row here holds no
--     lot key that survives one, and the geoparquet written from this table
--     has carried the number for exactly that reason.
--
-- An existing database keeps `rag.building_lots` until someone drops it; this
-- file does not, because dropping a table that still holds partitions nobody
-- has backfilled is not a decision a migration should make on its own:
--
--     DROP TABLE IF EXISTS rag.building_lots;

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.building_lot_intersections (
    -- The partition key leads, in the order 003_warehouse.sql explains.
    scrape_date          date NOT NULL,
    neighborhood         text NOT NULL,
    building_uid         bigint NOT NULL
        REFERENCES rag.buildings (building_uid) ON DELETE CASCADE,
    lot_uid              bigint NOT NULL
        REFERENCES rag.lots (lot_uid) ON DELETE CASCADE,
    -- Infolot's own lot number: the one key on this row that survives a
    -- reload of either side.
    lot_number           text,
    building_area_m2     double precision NOT NULL,
    intersection_area_m2 double precision NOT NULL,
    -- 100 * intersection_area_m2 / building_area_m2 — how much of the
    -- building's footprint sits on this particular lot.
    pct_of_building      double precision NOT NULL,
    -- The clipped slice itself, not the whole building. Left as a bare
    -- Geometry rather than typed Polygon/MultiPolygon: ST_Intersection of two
    -- polygons can legally return a GeometryCollection at the edges.
    geom                 geometry(Geometry, 4326),
    -- When this row was last published, set by the upsert rather than by the
    -- column default: on a re-run the default would still read as the first
    -- insert's timestamp.
    loaded_at            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, building_uid, lot_uid)
) PARTITION BY LIST (neighborhood);

-- Created on the parent, so every partition warehouse.ensure_partition adds
-- gets them without anyone remembering to.
CREATE INDEX IF NOT EXISTS building_lot_intersections_geom_idx
    ON silver.building_lot_intersections USING gist (geom);
CREATE INDEX IF NOT EXISTS building_lot_intersections_lot_idx
    ON silver.building_lot_intersections (lot_uid);
CREATE INDEX IF NOT EXISTS building_lot_intersections_lot_number_idx
    ON silver.building_lot_intersections (lot_number);

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

    -- ALTER TABLE on a partitioned table carries its partitions with it.
    EXECUTE format(
        'ALTER TABLE silver.building_lot_intersections OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON silver.building_lot_intersections TO %I', ro_role);
    END IF;
END
$$;
