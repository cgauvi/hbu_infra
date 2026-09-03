-- gold.map_cell_aggregates — every map layer dissolved onto the tile grid, so
-- a borough-wide view has something true to draw.
--
-- The five spatial layers this platform serves are all gated on zoom in the
-- map: below zoom 15 a lot is sub-pixel, and twenty-five thousand of them is a
-- solid grey rectangle that costs a second of browser time to produce. So the
-- map draws nothing at all down there, and "nothing" is the wrong answer to
-- *where in this borough is the headroom* — which is the one question a
-- zoomed-out view is for.
--
-- This table is that question's answer, precomputed. One row per (layer, cell),
-- where a cell is a Web Mercator tile at a zoom finer than the one being
-- looked at. Written by hbu_dataplatform's `map_cell_aggregates` asset — see
-- that repo's `urban_rag.tile_grid` for the grid arithmetic and
-- `urban_rag.postgis.compute_map_cell_aggregates` for the rollup.
--
-- ---------------------------------------------------------------------------
-- Why the cell is a tile and not a grid somebody chose
-- ---------------------------------------------------------------------------
--
-- A cell here is exactly `ST_TileEnvelope(cell_z, cell_x, cell_y)`, and the map
-- serves display zoom Z from cells at Z + 4. That is not a tidiness argument,
-- it is the whole bound:
--
--   * A tile at zoom Z contains exactly 4^4 = 256 tiles at zoom Z + 4. So a
--     served tile carries **at most 256 features, at every zoom**, by
--     construction — not by a LIMIT that silently truncates, and not by a
--     simplification whose cost still scales with the borough. The feature
--     fuse in hbu_rag_map's `mvt_tile` cannot fire on this table.
--   * Cell edges fall on tile edges, so no cell straddles two tiles and no
--     feature is cut, counted twice, or drawn along a seam.
--   * At Z + 4 a cell is 256/16 = 16 screen pixels. Coarse enough to be a
--     texture, fine enough that the borough's shape is still legible in it.
--
-- Levels 15 through 19 are built for every layer, uniformly, rather than only
-- the levels each layer's gate needs. The gates live in hbu_rag_map and change
-- when somebody tunes what is legible; making this table depend on them would
-- mean a re-materialisation of every borough to move one number in a different
-- repository.
--
-- ---------------------------------------------------------------------------
-- Two assignments, and both of them are additive
-- ---------------------------------------------------------------------------
--
-- This is the part to read before trusting a number here.
--
-- A lot straddles cells. If you count it in every cell its geometry touches,
-- the counts double-count, and the pyramid that rolls four children into a
-- parent compounds the error at every level. If you assign it to one cell and
-- take its area there, the area is wrong — you have credited a cell with land
-- that lies outside it.
--
-- So each measure uses the assignment that is exact *for that measure*:
--
--   * **Geometry measures** — `dissolved_area_m2`, `coverage_pct`, a street's
--     length — come from `ST_Intersection` with the cell. Cells at one level
--     are disjoint and tile the parent, so a parent's value is the sum of its
--     four children's and the total over a borough is the borough's own.
--   * **Feature measures** — `feature_count`, floor areas, dwellings, money —
--     come from `ST_PointOnSurface`: one representative point per feature, in
--     exactly one cell. The level-Z cell holding that point is the parent of
--     the level-(Z+1) cell holding it, so these roll up exactly too.
--
-- A consequence worth expecting rather than discovering: a cell can have
-- `feature_count = 0` and a non-empty `geom`, where a large lot's edge reaches
-- in but its representative point does not. That is honest — the cell is
-- covered by cadastre it does not own — and it is why `value` is NULL rather
-- than 0 on such a cell, so the map can shade it "not answered" instead of
-- "empty".
--
-- ---------------------------------------------------------------------------
-- Ratios are recomputed from the sums
-- ---------------------------------------------------------------------------
--
-- `value` on the capacity layer is 100 * sum(existing_floor) / sum(hbu_floor)
-- over the cell, **not** the mean of the per-lot percentages. Those are
-- different numbers — the mean of ratios is not the ratio of sums — and the
-- second one is what a reader of this map thinks they are being shown. The
-- band palette in hbu_rag_map's `_CAPACITY_BANDS` is applied to this column
-- unchanged, so getting it wrong would not look wrong.
--
-- The same rule holds at every level of the pyramid: a parent recomputes its
-- ratio from its own summed numerator and denominator rather than averaging
-- what its children reported.
--
-- No `-- requires:` header, for the reason sql/022 gives: this table names
-- nothing outside its own schema. The three tables it is *computed from* —
-- sql/007's streets, sql/019's gap and sql/022's massing — are read by the
-- asset at materialisation time, not by this DDL, and a missing one is that
-- run's failure rather than this file's.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO gold, public;

CREATE TABLE IF NOT EXISTS gold.map_cell_aggregates (
    -- The partition key leads, in the order 003_warehouse.sql explains.
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,

    -- Which map layer this cell summarises: 'lots', 'buildings', 'capacity',
    -- 'massing' or 'streets'. Named for the layer hbu_rag_map draws rather
    -- than for the table it came from, because that is what a tile request
    -- asks for — /tiles/lots/12/... is served from the rows where layer =
    -- 'lots' — and one indirection is enough.
    layer        text NOT NULL,

    -- The Web Mercator tile that *is* this cell. `cell_z` runs 15..19; the map
    -- serves display zoom Z from cell_z = Z + 4. See the header for why that
    -- offset is the bound on tile size rather than a preference.
    cell_z       smallint NOT NULL,
    cell_x       integer NOT NULL,
    cell_y       integer NOT NULL,

    -- -- what is in the cell -------------------------------------------------
    --
    -- Features whose representative point falls in this cell. Additive up the
    -- pyramid and across the borough; see the header on the two assignments.
    -- Zero is a real value: a cell reached by a neighbour's geometry and
    -- holding no feature of its own.
    feature_count integer NOT NULL DEFAULT 0,

    -- **The number the cell is shaded by**, and the reason this table has a
    -- generic column where the source tables have named ones. Five layers
    -- shaded on five different measures would be five style functions and five
    -- palettes in the browser; one column with its meaning declared beside it
    -- is one style function and one ramp per layer's own colour.
    --
    -- NULL means "not answered here" and is shaded as such — a cell with no
    -- feature of its own, or one whose denominator is zero. It never means 0.
    value        double precision,
    -- What `value` is, per layer. One of 'lots_per_km2', 'built_coverage_pct',
    -- 'used_pct', 'proposed_dwellings_per_ha', 'street_km_per_km2'. Carried on
    -- every row rather than looked up from `layer`, so a tile is
    -- self-describing and a reader of this table in SQL is never guessing at
    -- units.
    value_kind   text NOT NULL,

    -- -- how much of the cell the layer covers -------------------------------
    --
    -- From the clip, so exact. `coverage_pct` is 100 * dissolved / cell, and
    -- it is what says whether a low `value` means "sparse" or "outside the
    -- borough" — a cell beyond the boundary has no coverage at all, and a
    -- park has coverage with no buildings on it.
    dissolved_area_m2 double precision,
    cell_area_m2      double precision,
    coverage_pct      double precision,

    -- The measures that are this layer's own, packed rather than given
    -- columns: the five layers agree on nothing past the four above, and a
    -- wide table of mutually-exclusive nullable columns is a schema that has
    -- to be migrated every time a layer learns a new number. The tooltip
    -- reads them by name; `urban_rag.tile_grid.LAYER_MEASURES` is where the
    -- names per layer are declared.
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- EPSG:4326, the dissolved union of the layer's features clipped to the
    -- cell — not the cell rectangle. The difference is the point: at borough
    -- zoom the union is where the cadastre actually is, so the water, the
    -- rail yard and the park read as absent rather than as zero.
    --
    -- Unconstrained `Geometry` like every other spatial table here: four
    -- layers dissolve to polygons and `streets` to linework, and they share
    -- this column.
    geom      geometry(Geometry, 4326),
    loaded_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, layer, cell_z, cell_x, cell_y)
) PARTITION BY LIST (neighborhood);

-- The tile read, and the only one that matters for latency: "every cell of
-- this layer at this level inside this envelope". Leading on (layer, cell_z)
-- rather than on geom because that pair cuts the partition to a few hundred
-- rows before the geometry is looked at, at which point the GiST below has
-- almost nothing left to do.
CREATE INDEX IF NOT EXISTS map_cell_aggregates_layer_level_idx
    ON gold.map_cell_aggregates (layer, cell_z);
CREATE INDEX IF NOT EXISTS map_cell_aggregates_geom_idx
    ON gold.map_cell_aggregates USING gist (geom);

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
        'ALTER TABLE gold.map_cell_aggregates OWNER TO %I', app_role
    );

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON gold.map_cell_aggregates TO %I', ro_role
        );
    END IF;
END
$$;
