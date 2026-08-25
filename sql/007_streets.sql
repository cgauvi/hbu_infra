-- Streets — sides of the roadway, from Montreal's géobase double
--
-- Not the plain géobase, which draws one centre line per segment. A lot faces
-- one *side* of a street, and the side is where the curb and sidewalk limits
-- are, so the double is the layer a frontage question can be asked against —
-- see 008_lot_frontage.sql, which is the only reader of this table today.
--
-- Filled by hbu_dataplatform (urban_rag.postgis.load_streets) from its
-- silver/neighborhood_streets partitions: the city publishes the layer
-- island-wide, and the pipeline cuts it to a borough before loading, so the
-- rows here are already clipped to the (neighborhood, scrape_date) they carry.
--
-- `cote_rue_id` is the publisher's own key for a street side and is unique
-- across the island (91,546 of 91,546 in the first snapshot), which makes this
-- table's refresh an upsert against a real natural key rather than the
-- wholesale partition replacement rag.buildings needs — the same posture as
-- rag.lots and its lot_number.
--
-- `length_m` rather than `area_m2`: these are lines. `street_name` gets a
-- column of its own rather than a slot in `attributes` because it is what a
-- frontage row is read for — "22 m on Rue Jarry" is the answer, and digging
-- that back out of jsonb at every read would be work in the wrong place.
--
-- Owned by the same role as the rest of `rag`, handed over below.

SET search_path TO rag, public;

CREATE TABLE IF NOT EXISTS rag.streets (
    street_uid   bigserial PRIMARY KEY,
    -- COTE_RUE_ID in the published layer.
    cote_rue_id  text NOT NULL,
    -- NOM_VOIE. Nullable: an unnamed service lane is a real street side.
    street_name  text,
    neighborhood text NOT NULL,
    scrape_date  date NOT NULL,
    length_m     double precision,
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- EPSG:4326, matching every other geometry in this schema. MultiLineString
    -- because the source publishes MultiLineString and because clipping a side
    -- at a borough line can split it into two.
    geom         geometry(MultiLineString, 4326),
    UNIQUE (cote_rue_id, scrape_date)
);

CREATE INDEX IF NOT EXISTS streets_geom_idx ON rag.streets USING gist (geom);
CREATE INDEX IF NOT EXISTS streets_name_idx ON rag.streets (street_name);
CREATE INDEX IF NOT EXISTS streets_partition_idx
    ON rag.streets (neighborhood, scrape_date);

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

    EXECUTE format('ALTER TABLE rag.streets OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON rag.streets TO %I', ro_role);
    END IF;
END
$$;
