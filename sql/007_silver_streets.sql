-- silver.neighborhood_streets — the roadway centre lines, from the RQTT, one
-- cut cell's worth at a time.
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
-- province, and the pipeline takes the segments whose midpoint falls in the
-- cut cell it is running for, whole. Nothing is clipped — a segment belongs
-- to exactly one cell by its midpoint and is stored entire, so a lot on a
-- cell edge measures its frontage against the whole side and not against the
-- half that happened to fall on its side of a line. It used to be cut to the
-- borough, which is what the name still says; `neighborhood` is now the
-- borough outline the midpoint falls in, and NULL where no loaded borough
-- contains it, since a side can sit on ground no publisher's outline claims.
--
-- `cote_rue_id` is the publisher's own key for a segment — the RQTT's
-- `AQRP_UUID`, which is one per segment across the province, and not `IdRte`,
-- which carries both nulls and duplicates. That uniqueness makes it the
-- natural key this table's upsert conflicts on — one segment, one cell, one
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

-- The block 004_silver_building_lots.sql explains: a table still partitioned
-- on `neighborhood` is renamed `_by_neighborhood`, its indexes and constraints
-- suffixed `_bn`, so the CREATE below makes the cell-partitioned one beside it.
DO $migrate$
DECLARE
    target  regclass := to_regclass('silver.neighborhood_streets');
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
        target, 'neighborhood_streets_by_neighborhood'
    );

    RAISE NOTICE
        'silver.neighborhood_streets was LIST (neighborhood): renamed to '
        'silver.neighborhood_streets_by_neighborhood; suffixed _bn: %',
        array_to_string(renamed, ', ');
END
$migrate$;

CREATE TABLE IF NOT EXISTS silver.neighborhood_streets (
    -- The partition key leads, in the order 003_warehouse.sql explains. The
    -- cell columns are the side's own, taken at its midpoint (028_cell_key.sql
    -- for the address): a side belongs to the cell its midpoint is in. The
    -- borough is the outline containing that midpoint, and nullable — see the
    -- header — which is the one place in the lot chain it is.
    scrape_date    date NOT NULL,
    cell_key       text COLLATE "C" NOT NULL,
    cell_partition text COLLATE "C" NOT NULL,
    neighborhood   text,
    -- The publisher's AQRP_UUID, under this platform's COTE_RUE_ID.
    cote_rue_id  text NOT NULL,
    -- NomRte, under this platform's NOM_VOIE. Nullable: 231 of the Montreal
    -- box's 93,521 segments are unnamed, and a service lane is a real road.
    street_name  text,
    length_m     double precision,
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- EPSG:4326, matching every other geometry here. MultiLineString because
    -- the source publishes MultiLineString; nothing here splits a side any
    -- more, now that no borough line clips it.
    geom         geometry(MultiLineString, 4326),
    loaded_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, cell_partition, cote_rue_id)
) PARTITION BY LIST (cell_partition);

CREATE INDEX IF NOT EXISTS neighborhood_streets_geom_idx
    ON silver.neighborhood_streets USING gist (geom);
CREATE INDEX IF NOT EXISTS neighborhood_streets_name_idx
    ON silver.neighborhood_streets (street_name);
-- The map's per-borough read, which used to be partition pruning. The NULLs
-- — sides no loaded borough contains — are not in it, which is the right
-- answer to "this borough's streets".
CREATE INDEX IF NOT EXISTS neighborhood_streets_neighborhood_idx
    ON silver.neighborhood_streets (neighborhood, scrape_date)
    WHERE neighborhood IS NOT NULL;

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
