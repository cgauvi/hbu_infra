-- Which map features cover which lot.
--
-- The join a highest-and-best-use question actually needs, and the one thing
-- no id can give: a lot comes from Infolot, Quebec's cadastre, keyed by
-- `NO_LOT`; a zone comes from Montreal's Spectrum service, keyed by
-- `NUMERO_COMPLET`. The two publishers share no identifier, and the cadastre
-- carries no municipal zoning column - so "which rules apply to lot 1 234 567"
-- is a geometry question or it is nothing.
--
-- `rag.building_lots` is the same shape one layer over: clip the pair, keep
-- the slice and its share. The difference is which side the share is taken of.
-- A building is assigned to lots in proportion to *its own* footprint, because
-- the question there is where the building sits. Here it is the lot that gets
-- divided: a lot split between two zones is genuinely governed by both, and
-- `pct_of_lot` is what says which one governs most of it.
--
-- Not thresholded. A cadastral boundary and a zoning boundary are drawn by
-- different offices from different surveys, so they miss each other by
-- centimetres all along a street, and every lot picks up a sliver of its
-- neighbour's zone. Those rows are kept rather than dropped here, for the same
-- reason `rag.building_lots` keeps the corner of a triplex crossing a lot
-- line: the cutoff belongs to the question being asked, not to the geometry.
-- `pct_of_lot` is the column to filter on, and `rag.lot_documents`
-- (006_lot_documents.sql) ranks by it rather than picking for the caller.
--
-- Populated by hbu_dataplatform (`urban_rag.postgis.compute_lot_features`)
-- once that borough's `rag.lots` and `rag.features` rows have landed, and
-- refreshed the same way every other spatial table here is: a (neighborhood,
-- scrape_date) partition is deleted and reinserted wholesale.

SET search_path TO rag, public;

-- ---------------------------------------------------------------------------
-- rag.features: one correction before anything joins to it
--
-- The table ships (002_spatial.sql) with UNIQUE (source_table, feature_id,
-- scrape_date), which is unique per *borough* and not across them:
-- `source_table` is the file slug - `Reglement_urbanisme__VSP_REG_ZONE` - and
-- the slug drops the borough namespace the Spectrum path carries. Every
-- borough publishes a `VSP_REG_ZONE`, and zone numbers restart at C01-001 in
-- each one, so the second borough loaded would collide with the first and
-- silently lose its zones to ON CONFLICT DO NOTHING.
--
-- Done as a constraint swap rather than an edit to 002_spatial.sql because
-- that file's CREATE TABLE IF NOT EXISTS is a no-op on a database that already
-- has the table - editing it would fix only databases created after the edit.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    -- Guarded so this file still runs standalone on a database where
    -- 002_spatial.sql has not been applied: `'rag.features'::regclass` is an
    -- error, not a NULL, when the table is not there.
    IF to_regclass('rag.features') IS NULL THEN
        RAISE NOTICE
            'rag.features does not exist - apply 002_spatial.sql, then re-run '
            'this file to widen its uniqueness to the borough';
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'rag.features'::regclass
           AND conname = 'features_source_table_feature_id_scrape_date_key'
    ) THEN
        ALTER TABLE rag.features
            DROP CONSTRAINT features_source_table_feature_id_scrape_date_key;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'rag.features'::regclass
           AND conname = 'features_identity_key'
    ) THEN
        ALTER TABLE rag.features
            ADD CONSTRAINT features_identity_key
            UNIQUE (source_table, feature_id, neighborhood, scrape_date);
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- The join itself
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS rag.lot_features (
    lot_feature_uid bigserial PRIMARY KEY,
    lot_uid         bigint NOT NULL REFERENCES rag.lots (lot_uid) ON DELETE CASCADE,
    feature_uid     bigint NOT NULL REFERENCES rag.features (feature_uid) ON DELETE CASCADE,
    -- Copied down from rag.features so the query this table exists for -
    -- "the zoning grid covering this lot" - is one index scan on
    -- (source_table, feature_id) and not a second join to get there. They are
    -- exactly the two columns rag.chunks.feature_ids is matched against.
    source_table    text NOT NULL,
    feature_id      text NOT NULL,
    neighborhood    text NOT NULL,
    scrape_date     date NOT NULL,
    lot_area_m2     double precision NOT NULL,
    -- 0 for a feature that is a point or a line: those are recorded because
    -- they intersect the lot at all, not because they cover any of it.
    overlap_area_m2 double precision NOT NULL,
    -- 100 * overlap_area_m2 / lot_area_m2 - how much of the lot this feature
    -- covers. Sums to ~100 across one areal layer and means nothing summed
    -- across several, since the layers overlap each other freely.
    pct_of_lot      double precision NOT NULL,
    -- The clipped slice, not the whole feature. Bare Geometry rather than a
    -- typed MultiPolygon on both counts: rag.features holds points as well as
    -- polygons, and ST_Intersection of two polygons can legally return a
    -- GeometryCollection along a shared edge.
    geom            geometry(Geometry, 4326),
    UNIQUE (lot_uid, feature_uid)
);

CREATE INDEX IF NOT EXISTS lot_features_geom_idx ON rag.lot_features USING gist (geom);
CREATE INDEX IF NOT EXISTS lot_features_lot_idx ON rag.lot_features (lot_uid);
CREATE INDEX IF NOT EXISTS lot_features_feature_idx ON rag.lot_features (feature_uid);
-- The document path: filter to the layer that carries links, then match
-- feature_id against rag.chunks.feature_ids.
CREATE INDEX IF NOT EXISTS lot_features_source_idx
    ON rag.lot_features (source_table, feature_id);
CREATE INDEX IF NOT EXISTS lot_features_partition_idx
    ON rag.lot_features (neighborhood, scrape_date);

-- Same handover as every other file here: created by the master user because
-- only it can install PostGIS, owned by the role that owns the rag schema.
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

    EXECUTE format('ALTER TABLE rag.lot_features OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON rag.lot_features TO %I', ro_role);
    END IF;
END
$$;
