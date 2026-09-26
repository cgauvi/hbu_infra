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
-- ST_Intersection, one cut cell at a time, once the rag.buildings/rag.lots
-- rows of the boroughs that cell touches have landed, and written through
-- urban_rag.warehouse — see that module and 003_warehouse.sql for the
-- partitioning and the upsert this table's primary key exists to serve.
-- The lots are the cell's; the buildings are the whole snapshot's, so a
-- footprint on a cell edge is clipped against every lot it stands on.
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
--   * the key is (scrape_date, cell_partition, building_uid, lot_uid) — the
--     grain the old UNIQUE (building_uid, lot_uid) already declared, widened
--     by the partition it was always implicitly inside. It was the borough
--     until 2026-09-24 and is the cut cell since; see the block below.
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

-- ---------------------------------------------------------------------------
-- Moving to the tile axis, on a database that already holds the table
-- ---------------------------------------------------------------------------
--
-- The table below is `LIST (cell_partition)`. The one a database created
-- before 2026-09-24 holds is `LIST (neighborhood)`, and a partition key cannot
-- be altered in place — so that table is renamed `<table>_by_neighborhood`
-- and the CREATE that follows makes the new one beside it. Renamed and not
-- dropped: the repartition is gated on a borough's rows adding up the same
-- across the two axes, which needs the old rows readable, and a later cleanup
-- drops them once it passes. The old table's foreign keys to rag.lots still
-- cascade, so a borough reload empties its rows exactly as it did before.
--
-- Its indexes and constraints are renamed with it, suffixed `_bn`, for one
-- reason: index names are per schema, so `CREATE INDEX IF NOT EXISTS <name>`
-- below would find the old table's index under that name and silently create
-- nothing on the new one. The LIST children and month leaves keep their names
-- — `<table>__vsmpe__202609` cannot collide with the new table's
-- `<table>__03023033301021__202609`.
--
-- Idempotent: a second run finds the table partitioned on `cell_partition`
-- and does nothing. The same block heads every file of the lot chain; this is
-- the one that explains it.

DO $migrate$
DECLARE
    target  regclass := to_regclass('silver.building_lot_intersections');
    old_key text;
    item    record;
    renamed text[] := '{}';
BEGIN
    IF target IS NULL THEN
        RETURN;
    END IF;

    SELECT a.attname
      INTO old_key
      FROM pg_partitioned_table p
      JOIN pg_attribute a
        ON a.attrelid = p.partrelid AND a.attnum = p.partattrs[0]
     WHERE p.partrelid = target;

    IF old_key IS DISTINCT FROM 'neighborhood' THEN
        RETURN;
    END IF;

    -- The indexes that back no constraint. Renaming the primary key below
    -- carries its index with it, and renaming that index here as well would
    -- suffix it twice.
    FOR item IN
        SELECT i.indexrelid::regclass AS index_oid, ic.relname AS name
          FROM pg_index i
          JOIN pg_class ic ON ic.oid = i.indexrelid
         WHERE i.indrelid = target
           AND NOT EXISTS (
               SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid
           )
    LOOP
        EXECUTE format(
            'ALTER INDEX %s RENAME TO %I', item.index_oid, item.name || '_bn'
        );
        renamed := renamed || item.name;
    END LOOP;

    FOR item IN
        SELECT conname AS name
          FROM pg_constraint
         WHERE conrelid = target AND contype IN ('p', 'u', 'f', 'c')
    LOOP
        EXECUTE format(
            'ALTER TABLE %s RENAME CONSTRAINT %I TO %I',
            target, item.name, item.name || '_bn'
        );
        renamed := renamed || item.name;
    END LOOP;

    EXECUTE format(
        'ALTER TABLE %s RENAME TO %I',
        target, 'building_lot_intersections_by_neighborhood'
    );

    RAISE NOTICE
        'silver.building_lot_intersections was LIST (neighborhood): renamed to '
        'silver.building_lot_intersections_by_neighborhood; suffixed _bn: %',
        array_to_string(renamed, ', ');
END
$migrate$;

CREATE TABLE IF NOT EXISTS silver.building_lot_intersections (
    -- The partition key leads, in the order 003_warehouse.sql explains. The
    -- cell columns are the lot's own (028_cell_key.sql): a row belongs to the
    -- cut cell that owns its lot. The borough stays as an attribute — the map
    -- reads by it — and is the lot's, so a cell astride a borough line holds
    -- rows of both.
    scrape_date          date NOT NULL,
    cell_key             text COLLATE "C" NOT NULL,
    cell_partition       text COLLATE "C" NOT NULL,
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
    PRIMARY KEY (scrape_date, cell_partition, building_uid, lot_uid)
) PARTITION BY LIST (cell_partition);

-- Created on the parent, so every partition warehouse.ensure_partition adds
-- gets them without anyone remembering to.
CREATE INDEX IF NOT EXISTS building_lot_intersections_geom_idx
    ON silver.building_lot_intersections USING gist (geom);
CREATE INDEX IF NOT EXISTS building_lot_intersections_lot_idx
    ON silver.building_lot_intersections (lot_uid);
CREATE INDEX IF NOT EXISTS building_lot_intersections_lot_number_idx
    ON silver.building_lot_intersections (lot_number);
-- The map reads a borough at a time, and the borough is no longer the
-- partition: this is what used to be pruning.
CREATE INDEX IF NOT EXISTS building_lot_intersections_neighborhood_idx
    ON silver.building_lot_intersections (neighborhood, scrape_date);

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
