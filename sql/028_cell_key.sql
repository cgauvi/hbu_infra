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
-- What this file does NOT do
-- ---------------------------------------------------------------------------
--
-- `cell_partition` is added beside it and left NULL. It is a *prefix* of
-- cell_key, and how long a prefix depends on the cut - the variable-depth set
-- of cells the pipeline partitions on - which is a checked-in constant in the
-- dataplatform (`urban_rag.tile_cut`) and is not seeded yet. Nothing
-- repartitions here: every table is still PARTITION BY LIST (neighborhood),
-- and these two columns are nullable, non-key, and read by nothing.
--
-- The silver and gold tables do not get these columns here either. Their rows
-- inherit the lot's address rather than deriving their own, so the column
-- lands with the repartition that needs it rather than sitting NULL on twenty
-- tables in the meantime.

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
-- The column, on the three tables that derive it from their own geometry
--
-- `rag.lots`, `rag.buildings` and `rag.features` are plain tables, not
-- partitioned ones, so this is an ADD COLUMN and an index rather than a
-- migration. Everything downstream of them is lot-keyed and inherits the lot's
-- address.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    target text;
BEGIN
    FOREACH target IN ARRAY ARRAY['rag.lots', 'rag.buildings', 'rag.features']
    LOOP
        IF to_regclass(target) IS NULL THEN
            RAISE NOTICE '% does not exist - apply 002_spatial.sql first', target;
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
