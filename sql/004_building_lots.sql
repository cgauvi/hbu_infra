-- The building x lot join: for each footprint clipped to the lot(s) it
-- actually falls in, one row holding that slice's geometry and its share of
-- the building's area.
--
-- requires: rag.buildings
--
-- A building spanning several lots — a school, a warehouse, an apartment
-- tower — gets one row per lot it overlaps, each carrying only the portion
-- of the footprint inside that lot; nothing here assigns the whole building
-- to a single "primary" parcel. Computed by hbu_dataplatform
-- (urban_rag.postgis.compute_intersections) with ST_Intersection once that
-- borough's rag.buildings/rag.lots rows have landed — see its README.
--
-- Refreshed the same way rag.buildings/rag.lots are: a (neighborhood,
-- scrape_date) partition is deleted and reinserted, not upserted row by row,
-- because a building carries no key that survives a re-scrape.
--
-- Owned by the same role as the rest of `rag`, handed over below.

SET search_path TO rag, public;

CREATE TABLE IF NOT EXISTS rag.building_lots (
    building_lot_uid     bigserial PRIMARY KEY,
    building_uid         bigint NOT NULL REFERENCES rag.buildings (building_uid) ON DELETE CASCADE,
    lot_uid              bigint NOT NULL REFERENCES rag.lots (lot_uid) ON DELETE CASCADE,
    neighborhood         text NOT NULL,
    scrape_date          date NOT NULL,
    building_area_m2     double precision NOT NULL,
    intersection_area_m2 double precision NOT NULL,
    -- 100 * intersection_area_m2 / building_area_m2 — how much of the
    -- building's footprint sits on this particular lot.
    pct_of_building      double precision NOT NULL,
    -- The clipped slice itself, not the whole building. Left as a bare
    -- Geometry rather than typed Polygon/MultiPolygon: ST_Intersection of two
    -- polygons can legally return a GeometryCollection at the edges.
    geom                 geometry(Geometry, 4326),
    UNIQUE (building_uid, lot_uid)
);

CREATE INDEX IF NOT EXISTS building_lots_geom_idx ON rag.building_lots USING gist (geom);
CREATE INDEX IF NOT EXISTS building_lots_lot_idx ON rag.building_lots (lot_uid);
CREATE INDEX IF NOT EXISTS building_lots_partition_idx
    ON rag.building_lots (neighborhood, scrape_date);

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

    EXECUTE format('ALTER TABLE rag.building_lots OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON rag.building_lots TO %I', ro_role);
    END IF;
END
$$;
