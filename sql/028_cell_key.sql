-- cell_key — a permanent spatial address for every row that has geometry.
--
-- The quadkey of a representative point of the row's shape, at zoom 19. One
-- character per level, each the two bits of the Web Mercator tile's (x, y) at
-- that level, so:
--
--     lot 1 740 794, Villeray   ->   0302303330102123123
--
-- Three properties, and every use of this column is one of them:
--
--   * a prefix is an ancestor, exactly - `left(cell_key, 13)` is the zoom-13
--     tile containing the point, and it is the same cell the dataplatform's
--     `tile_grid.parent_of` reaches by halving the indices;
--   * lexicographic order is Z-order, so a btree on it clusters ground that is
--     near on the map into pages that are near on disk - which is why the
--     index below leads with it;
--   * the zoom is the length, so one column addresses every level at once and
--     a variable-depth partition scheme needs no second column to say which
--     level a row is cut at.
--
-- The grid is the one already in this database: `gold.map_cell_aggregates`
-- stores the same cells as `(cell_z, cell_x, cell_y)`, and
-- `warehouse.quadkey` below is that arithmetic written once more, as a string.
-- The dataplatform's `urban_rag.tile_grid` is the third copy and the tests
-- assert the three agree - a grid written twice is a grid that will disagree
-- with itself.
--
-- ---------------------------------------------------------------------------
-- Why ST_PointOnSurface and not ST_Centroid
-- ---------------------------------------------------------------------------
--
-- A centroid is not guaranteed to be inside its polygon, and this cadastre has
-- the shapes that prove it: lot 1 740 794 is a flag lot with a 15 m pole to
-- Jarry, and lots wrapped around a neighbour are ordinary here. A centroid
-- outside the parcel addresses a cell the parcel does not occupy - which is
-- not a rounding error, it is the wrong partition.
--
-- ST_PointOnSurface is guaranteed interior, and it is deterministic for a
-- given geometry, which is the other half of what a permanent address needs.
--
-- ---------------------------------------------------------------------------
-- `cell_partition`, and who writes it
-- ---------------------------------------------------------------------------
--
-- `cell_partition` is the *prefix* of cell_key that names the cut cell owning
-- the row - how long a prefix depends on the cut, the variable-depth set of
-- cells the lot chain is partitioned on, which is a checked-in constant in
-- the dataplatform (`urban_rag.tile_cut`). `warehouse.tile_of` below resolves
-- a key against a cut handed in as an array; the dataplatform's loaders call
-- it with the live cut on every INSERT, so both columns are written on the
-- way in and a reload never leaves them NULL.
--
-- This file backfills `cell_key` only. `cell_partition` needs the cut, which
-- lives in Python, so a row loaded before the loaders wrote it gets its
-- partition from the next `neighborhood_cadastre` run of its borough - not
-- from `db init`. The count of rows that have a key and no partition is the
-- number to read before trusting a tile run.
--
-- The silver and gold tables of the lot chain carry both columns as well -
-- see each table's own file - inheriting the lot's address rather than
-- deriving their own, and they are partitioned on `cell_partition`.

SET search_path TO warehouse, public;

-- ---------------------------------------------------------------------------
-- The grid arithmetic, as a function
--
-- IMMUTABLE and PARALLEL SAFE so the backfill below can be parallelised and so
-- an expression index on it stays legal. STRICT because a NULL coordinate has
-- no cell, and a row with no geometry should carry NULL rather than the
-- address of Null Island.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION warehouse.quadkey(
    lon double precision,
    lat double precision,
    z   integer
)
RETURNS text
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
AS $$
    WITH cell AS (
        SELECT
            -- Clamped at both ends: a longitude of exactly 180 would index one
            -- column past the last, and Mercator has no latitude beyond about
            -- 85.05 to index at all.
            greatest(0, least((1 << z) - 1,
                floor(((lon + 180.0) / 360.0) * (1 << z))::bigint
            )) AS x,
            greatest(0, least((1 << z) - 1,
                floor(
                    (
                        1.0 - asinh(tan(radians(
                            greatest(-85.0511287798, least(85.0511287798, lat))
                        ))) / pi()
                    ) / 2.0 * (1 << z)
                )::bigint
            )) AS y
    )
    SELECT string_agg(
               (
                   (CASE WHEN (x >> (lvl - 1)) & 1 = 1 THEN 1 ELSE 0 END)
                 + (CASE WHEN (y >> (lvl - 1)) & 1 = 1 THEN 2 ELSE 0 END)
               )::text,
               ''
               ORDER BY lvl DESC
           )
      FROM cell, generate_series(1, z) AS lvl;
$$;

COMMENT ON FUNCTION warehouse.quadkey(double precision, double precision, integer) IS
    'The quadkey of the zoom-z Web Mercator tile containing (lon, lat). Mirrors '
    'urban_rag.tile_grid.quadkey_of; tests/unit/test_tile_grid.py asserts the two agree.';


-- ---------------------------------------------------------------------------
-- The cut cell that owns a key
--
-- A prefix walk over the cut handed in: the member that prefixes the key is
-- the cell, and because no member of a valid cut nests inside another there
-- is at most one. NULL for ground the cut does not cover, which the loaders
-- turn into a failure rather than a row nobody will compute over.
--
-- The cut is a parameter rather than a table because it is a checked-in
-- constant on the dataplatform side (`urban_rag.tile_cut.CUT`) and the one
-- copy that exists should be the one that is passed in - a second copy here
-- would be the one that goes stale.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION warehouse.tile_of(cell_key text, cut text[])
RETURNS text
LANGUAGE sql
IMMUTABLE STRICT PARALLEL SAFE
AS $$
    SELECT cell
      FROM unnest(cut) AS cell
     WHERE left(cell_key, length(cell)) = cell
     ORDER BY length(cell) DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION warehouse.tile_of(text, text[]) IS
    'The member of cut that prefixes cell_key, or NULL for ground the cut does '
    'not cover. Mirrors urban_rag.tile_cut.cell_partition_of.';


-- ---------------------------------------------------------------------------
-- The columns, on the four tables that derive them from their own geometry
--
-- `rag.lots`, `rag.buildings`, `rag.features` and `rag.addresses` are plain
-- tables, not partitioned ones, so this is an ADD COLUMN and an index rather
-- than a migration. Everything downstream of the lots is lot-keyed and
-- inherits the lot's address; the addresses are points and own theirs.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    target text;
BEGIN
    FOREACH target IN ARRAY ARRAY[
        'rag.lots', 'rag.buildings', 'rag.features', 'rag.addresses'
    ]
    LOOP
        IF to_regclass(target) IS NULL THEN
            RAISE NOTICE '% does not exist - apply 002_spatial.sql (or 026 for the addresses) first', target;
            CONTINUE;
        END IF;

        -- Nullable on purpose. A row whose geometry is NULL, or empty, has no
        -- representative point and so no address; NOT NULL here would make
        -- that row unloadable rather than visibly unaddressed, and "how many
        -- rows have no cell_key" is a question worth being able to ask.
        EXECUTE format(
            'ALTER TABLE %s ADD COLUMN IF NOT EXISTS cell_key text', target
        );
        EXECUTE format(
            'ALTER TABLE %s ADD COLUMN IF NOT EXISTS cell_partition text', target
        );

        -- COLLATE "C" is not decoration. `cell_key >= lo AND cell_key < hi` is
        -- how a cell's rows are selected, and under any other collation the
        -- ordering of the digits is the locale's business rather than the
        -- grid's - so the range would silently return the wrong ground. Set
        -- per column rather than relying on the database default, because the
        -- default travels with a restore and this must not.
        EXECUTE format(
            'ALTER TABLE %s ALTER COLUMN cell_key TYPE text COLLATE "C"', target
        );
        EXECUTE format(
            'ALTER TABLE %s ALTER COLUMN cell_partition TYPE text COLLATE "C"',
            target
        );
    END LOOP;
END
$$;

-- Leading with `cell_key` rather than with the partition: this is the index a
-- prefix range answers, and the Z-order property means a range over it is a
-- range over contiguous ground.
CREATE INDEX IF NOT EXISTS lots_cell_key_idx
    ON rag.lots (cell_key) WHERE cell_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS buildings_cell_key_idx
    ON rag.buildings (cell_key) WHERE cell_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS features_cell_key_idx
    ON rag.features (cell_key) WHERE cell_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS addresses_cell_key_idx
    ON rag.addresses (cell_key) WHERE cell_key IS NOT NULL;

-- The read every tile run opens with - "the lots this cell owns, this
-- month" - and the one `tiles_of_neighborhood` makes the other way round.
CREATE INDEX IF NOT EXISTS lots_cell_partition_idx
    ON rag.lots (cell_partition, scrape_date) WHERE cell_partition IS NOT NULL;
CREATE INDEX IF NOT EXISTS buildings_cell_partition_idx
    ON rag.buildings (cell_partition, scrape_date) WHERE cell_partition IS NOT NULL;
CREATE INDEX IF NOT EXISTS addresses_cell_partition_idx
    ON rag.addresses (cell_partition, scrape_date) WHERE cell_partition IS NOT NULL;


-- ---------------------------------------------------------------------------
-- Backfill
--
-- Idempotent - only rows that have no address yet - so this file can be
-- re-applied, and so a partition loaded before the pipeline started writing
-- the column is picked up by the next `db init` rather than needing a
-- re-materialisation.
--
-- 19 is `urban_rag.tile_grid.BASE_CELL_ZOOM`, the depth the pyramid is already
-- seeded at. Storing at full depth is what lets the cut change later without
-- recomputing a single row: every coarser address is a prefix of this one.
-- ---------------------------------------------------------------------------

UPDATE rag.lots
   SET cell_key = warehouse.quadkey(
           ST_X(ST_PointOnSurface(geom)), ST_Y(ST_PointOnSurface(geom)), 19
       )
 WHERE cell_key IS NULL
   AND geom IS NOT NULL
   AND NOT ST_IsEmpty(geom);

UPDATE rag.buildings
   SET cell_key = warehouse.quadkey(
           ST_X(ST_PointOnSurface(geom)), ST_Y(ST_PointOnSurface(geom)), 19
       )
 WHERE cell_key IS NULL
   AND geom IS NOT NULL
   AND NOT ST_IsEmpty(geom);

-- `rag.features` holds points and lines as well as polygons, and
-- ST_PointOnSurface is defined on all three - on a point it is the point.
UPDATE rag.features
   SET cell_key = warehouse.quadkey(
           ST_X(ST_PointOnSurface(geom)), ST_Y(ST_PointOnSurface(geom)), 19
       )
 WHERE cell_key IS NULL
   AND geom IS NOT NULL
   AND NOT ST_IsEmpty(geom);

UPDATE rag.addresses
   SET cell_key = warehouse.quadkey(ST_X(geom), ST_Y(geom), 19)
 WHERE cell_key IS NULL
   AND geom IS NOT NULL
   AND NOT ST_IsEmpty(geom);
