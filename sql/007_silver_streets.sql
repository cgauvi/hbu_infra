-- silver.neighborhood_streets — the roadway centre lines, from the RQTT, cut
-- to one borough.
--
-- The RQTT (Référentiel québécois du transport terrestre) is the MRNF's
-- province-wide road network, and it replaced three municipal layers at once:
-- Montreal's géobase double, Quebec City's vque_18 and Saguenay's
-- sag-reseau-routier. One publication, one schema, so a new city needs a
-- bounding box rather than a new branch.
--
-- It draws one centre line per segment where the géobase double drew two
-- sides, one along each curb. That matters less than it sounds: the frontage
-- measure in 008_silver_lot_frontage.sql is the boundary a lot *shares* with a
-- road parcel and needs no line at all. What the line does is identify which
-- parcels are roadway and name the street, and a centre line does both — it
-- runs down the axis of the road parcel rather than hugging its edge. Where it
-- does cost something is the fallback reach, which is measured from the line;
-- see postgis.DEFAULT_FRONTAGE_FALLBACK_BUFFERS_M.
--
-- Filled by hbu_dataplatform's `neighborhood_streets` asset from its own
-- silver/neighborhood_streets partitions: the MRNF publishes the layer for the
-- province, and the pipeline cuts it to a borough before loading, so the rows
-- here are already clipped to the (neighborhood, scrape_date) they carry.
--
-- `cote_rue_id` is the publisher's own key for a segment — the RQTT's
-- `AQRP_UUID`, which is one per segment across the province, and not `IdRte`,
-- which carries both nulls and duplicates. That uniqueness makes it the
-- natural key this table's upsert conflicts on — one segment, one borough, one
-- day, one row.
--
-- The *name* `cote_rue_id` is a côté de rue, a side of street, and nothing
-- here is one any more. It is kept deliberately: it is in this primary key and
-- silver.lot_frontage's, denormalised into gold.lot_profiles, and read by the
-- map's tile queries, and re-keying all of that to win a better word would
-- risk the lineage to fix a noun.
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
-- unique across the province, and already what silver.lot_frontage denormalised
-- rather than the serial. The old table is left in place; drop it once nothing
-- reads it:
--
--     DROP TABLE IF EXISTS rag.streets;

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.neighborhood_streets (
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- The publisher's AQRP_UUID, under this platform's COTE_RUE_ID.
    cote_rue_id  text NOT NULL,
    -- NomRte, under this platform's NOM_VOIE. Nullable: 231 of the Montreal
    -- box's 93,521 segments are unnamed, and a service lane is a real road.
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
