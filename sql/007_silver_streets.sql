-- silver.neighborhood_streets — sides of the roadway, from Montreal's géobase
-- double, cut to one borough.
--
-- Not the plain géobase, which draws one centre line per segment. A lot faces
-- one *side* of a street, and the side is where the curb and sidewalk limits
-- are, so the double is the layer a frontage question can be asked against —
-- see 008_silver_lot_frontage.sql, which is the only reader of this table
-- today.
--
-- Filled by hbu_dataplatform's `neighborhood_streets` asset from its own
-- silver/neighborhood_streets partitions: the city publishes the layer
-- island-wide, and the pipeline cuts it to a borough before loading, so the
-- rows here are already clipped to the (neighborhood, scrape_date) they carry.
--
-- `cote_rue_id` is the publisher's own key for a street side and is unique
-- across the island (91,546 of 91,546 in the first snapshot), which makes it
-- the natural key this table's upsert conflicts on — one street side, one
-- borough, one day, one row.
--
-- `length_m` rather than `area_m2`: these are lines. `street_name` gets a
-- column of its own rather than a slot in `attributes` because it is what a
-- frontage row is read for — "22 m on Rue Jarry" is the answer, and digging
-- that back out of jsonb at every read would be work in the wrong place.
--
-- `attributes` keeps everything else the layer publishes, unchanged. The
-- source adds and retires columns between releases, and a schema that needs a
-- migration each time the city edits a layer will not survive the pipeline —
-- the same posture rag.features takes.
--
-- Moved here from rag.streets, and the surrogate `street_uid` is gone with the
-- move. A partitioned table's primary key must contain its partition keys, so
-- a bigserial could not be one; and nothing needed it to be, because the key
-- that means anything here was always `cote_rue_id` - the publisher's own,
-- unique across the island, and already what silver.lot_frontage denormalised
-- rather than the serial. The old table is left in place; drop it once nothing
-- reads it:
--
--     DROP TABLE IF EXISTS rag.streets;

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.neighborhood_streets (
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- COTE_RUE_ID in the published layer.
    cote_rue_id  text NOT NULL,
    -- NOM_VOIE. Nullable: an unnamed service lane is a real street side.
    street_name  text,
    length_m     double precision,
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- EPSG:4326, matching every other geometry here. MultiLineString because
    -- the source publishes MultiLineString and because clipping a side at a
    -- borough line can split it into two.
    geom         geometry(MultiLineString, 4326),
    loaded_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, cote_rue_id)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS neighborhood_streets_geom_idx
    ON silver.neighborhood_streets USING gist (geom);
CREATE INDEX IF NOT EXISTS neighborhood_streets_name_idx
    ON silver.neighborhood_streets (street_name);

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

    EXECUTE format(
        'ALTER TABLE silver.neighborhood_streets OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON silver.neighborhood_streets TO %I', ro_role);
    END IF;
END
$$;
