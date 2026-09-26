-- silver.lot_features — which map features cover which lot.
--
-- The join a highest-and-best-use question actually needs, and the one thing
-- no id can give: a lot comes from Infolot, Quebec's cadastre, keyed by
-- `NO_LOT`; a zone comes from Montreal's Spectrum service, keyed by
-- `NUMERO_COMPLET`. The two publishers share no identifier, and the cadastre
-- carries no municipal zoning column — so "which rules apply to lot 1 234 567"
-- is a geometry question or it is nothing.
--
-- `silver.building_lot_intersections` is the same shape one layer over: clip
-- the pair, keep the slice and its share. The difference is which side the
-- share is taken of. A building is assigned to lots in proportion to *its own*
-- footprint, because the question there is where the building sits. Here it is
-- the lot that gets divided: a lot split between two zones is genuinely
-- governed by both, and `pct_of_lot` is what says which one governs most of it.
--
-- Not thresholded. A cadastral boundary and a zoning boundary are drawn by
-- different offices from different surveys, so they miss each other by
-- centimetres all along a street, and every lot picks up a sliver of its
-- neighbour's zone. Those rows are kept rather than dropped here, for the same
-- reason the building join keeps the corner of a triplex crossing a lot line:
-- the cutoff belongs to the question being asked, not to the geometry.
-- `pct_of_lot` is the column to filter on, and `rag.lot_documents`
-- (006_lot_documents.sql) ranks by it rather than picking for the caller.
--
-- Computed by hbu_dataplatform (`urban_rag.postgis.compute_lot_features`) one
-- cut cell at a time — the cell's `rag.lots` against every `rag.features` row
-- in the snapshot, so a zone filed by the borough next door reaches the lot
-- it actually covers — and written through `urban_rag.warehouse`; see
-- 003_warehouse.sql for the partitioning and the upsert this table's primary
-- key exists to serve.
--
-- Moved here from rag.lot_features for the reason 004 gives for its own
-- table, and with the same three changes: no surrogate `lot_feature_uid`, the
-- partition keys leading the primary key, and `lot_number` carried down from
-- rag.lots so a row holds a lot key that survives a reload. The old table is
-- left in place; drop it once nothing reads it:
--
--     DROP TABLE IF EXISTS rag.lot_features;

SET search_path TO silver, public;

-- ---------------------------------------------------------------------------
-- rag.features: one correction before anything joins to it
--
-- The table shipped (002_spatial.sql) with UNIQUE (source_table, feature_id,
-- scrape_date), which is unique per *borough* and not across them:
-- `source_table` is the file slug — `Reglement_urbanisme__VSP_REG_ZONE` — and
-- the slug drops the borough namespace the Spectrum path carries. Every
-- borough publishes a `VSP_REG_ZONE`, and zone numbers restart at C01-001 in
-- each one, so the second borough loaded would collide with the first and
-- silently lose its zones to ON CONFLICT DO NOTHING.
--
-- This file first widened the key by `neighborhood`, which worked because a
-- borough was 1:1 with the namespace that actually tells the rows apart. Since
-- the lot chain moved to the tile axis the key is on that namespace itself —
-- `source_namespace`, 027_features_source_namespace.sql — because a borough is
-- now an attribute a feature carries rather than the unit anything reads it
-- by, and a lot's zones are found across borough lines. The swap 027 declined
-- "until the partition key moves" is made here: `features_identity_key` is
-- UNIQUE (source_table, feature_id, source_namespace, scrape_date), which is
-- what the dataplatform's `load_features` conflicts on.
--
-- Done as a constraint swap because 002's CREATE TABLE IF NOT EXISTS is a
-- no-op on a database that already has the table: 002 declares the new key
-- for a fresh database, and this is what reaches the ones that already exist.
--
-- One thing the swap will not do on its own is delete. Under the new key two
-- rows can collide that the old one kept apart: the same zone loaded by two
-- arrondissements of a city that files one layer (Quebec City), or rows still
-- carrying the empty namespace, which 027 backfills nothing into. Where any
-- exist the block warns, names a few and leaves the old key in place — the
-- next `neighborhood_cadastre` load then fails on its ON CONFLICT rather than
-- landing anything under a key it cannot upsert against. The fix is to delete
-- the duplicated rows, or re-materialize their borough, and re-run this init.
-- ---------------------------------------------------------------------------

DO $$
DECLARE
    on_neighborhood boolean;
    duplicates      bigint;
    sample          text;
BEGIN
    -- Guarded so this file still runs standalone on a database where
    -- 002_spatial.sql has not been applied: `'rag.features'::regclass` is an
    -- error, not a NULL, when the table is not there.
    IF to_regclass('rag.features') IS NULL THEN
        RAISE NOTICE
            'rag.features does not exist - apply 002_spatial.sql, then re-run '
            'this file to move its uniqueness onto the namespace';
        RETURN;
    END IF;

    -- A database older than 027 has no namespace column to key on yet, and
    -- 027 runs after this file. Skipping rather than failing lets that same
    -- init add the column; the next one makes the swap.
    IF NOT EXISTS (
        SELECT 1 FROM pg_attribute
         WHERE attrelid = 'rag.features'::regclass
           AND attname = 'source_namespace'
           AND NOT attisdropped
    ) THEN
        RAISE NOTICE
            'rag.features has no source_namespace yet - 027 adds it; re-run '
            'db init to move features_identity_key onto it';
        RETURN;
    END IF;

    -- Whether the key still names the borough.
    SELECT EXISTS (
        SELECT 1
          FROM pg_constraint c
          JOIN pg_attribute a
            ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
         WHERE c.conrelid = 'rag.features'::regclass
           AND c.conname = 'features_identity_key'
           AND a.attname = 'neighborhood'
    ) INTO on_neighborhood;

    IF NOT on_neighborhood AND EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'rag.features'::regclass
           AND conname = 'features_identity_key'
    ) THEN
        -- Already on the namespace: 002 on a fresh database, or an earlier
        -- run of this block.
        RETURN;
    END IF;

    SELECT count(*)
      INTO duplicates
      FROM (
          SELECT 1
            FROM rag.features
           GROUP BY source_table, feature_id, source_namespace, scrape_date
          HAVING count(*) > 1
      ) d;

    IF duplicates > 0 THEN
        SELECT string_agg(
                   format('%s %s [%s] %s',
                          source_table, feature_id, source_namespace, scrape_date),
                   '; ' ORDER BY source_table, feature_id, scrape_date
               )
          INTO sample
          FROM (
              SELECT source_table, feature_id, source_namespace, scrape_date
                FROM rag.features
               GROUP BY source_table, feature_id, source_namespace, scrape_date
              HAVING count(*) > 1
               ORDER BY source_table, feature_id, scrape_date
               LIMIT 3
          ) d;
        RAISE WARNING
            'rag.features: % (source_table, feature_id, source_namespace, '
            'scrape_date) tuples are held by more than one row - e.g. % - so '
            'features_identity_key stays on the borough. Delete the duplicated '
            'rows (one zone loaded by two arrondissements, or rows still '
            'carrying the empty namespace - see 027) and re-run db init; '
            'load_features cannot upsert until the key has moved.',
            duplicates, sample;
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

    IF on_neighborhood THEN
        ALTER TABLE rag.features DROP CONSTRAINT features_identity_key;
    END IF;

    ALTER TABLE rag.features
        ADD CONSTRAINT features_identity_key
        UNIQUE (source_table, feature_id, source_namespace, scrape_date);
    RAISE NOTICE
        'rag.features: features_identity_key is now '
        '(source_table, feature_id, source_namespace, scrape_date)';
END
$$;

-- ---------------------------------------------------------------------------
-- The join itself
--
-- Keyed on (lot_uid, source_table, feature_id) rather than on the old
-- (lot_uid, feature_uid): `feature_uid` is a bigserial that a re-scrape mints
-- again, while the pair (source_table, feature_id) is what the corpus cites
-- and what every join from geometry to a document matches on. Same grain,
-- stated in the columns a reader can actually name.
-- ---------------------------------------------------------------------------

-- The block 004_silver_building_lots.sql explains: a table still partitioned
-- on `neighborhood` is renamed `_by_neighborhood`, its indexes and constraints
-- suffixed `_bn`, so the CREATE below makes the cell-partitioned one beside it.
DO $migrate$
DECLARE
    target  regclass := to_regclass('silver.lot_features');
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
        'ALTER TABLE %s RENAME TO %I', target, 'lot_features_by_neighborhood'
    );

    RAISE NOTICE
        'silver.lot_features was LIST (neighborhood): renamed to '
        'silver.lot_features_by_neighborhood; suffixed _bn: %',
        array_to_string(renamed, ', ');
END
$migrate$;

CREATE TABLE IF NOT EXISTS silver.lot_features (
    -- The partition key leads, in the order 003_warehouse.sql explains; the
    -- cell columns are the lot's (028_cell_key.sql) and the borough is the
    -- lot's too, carried for the map's per-borough reads. A feature filed by
    -- another borough is still this lot's row: that is what the global pool
    -- buys, and rag.features says whose the feature is.
    scrape_date     date NOT NULL,
    cell_key        text COLLATE "C" NOT NULL,
    cell_partition  text COLLATE "C" NOT NULL,
    neighborhood    text NOT NULL,
    lot_uid         bigint NOT NULL
        REFERENCES rag.lots (lot_uid) ON DELETE CASCADE,
    -- Exactly the two columns rag.chunks.feature_ids is matched against, so
    -- "the zoning grid covering this lot" is one index scan and not a second
    -- join to get there.
    source_table    text NOT NULL,
    feature_id      text NOT NULL,
    -- Infolot's own lot number, and rag.features' surrogate, both carried for
    -- the readers that have one and not the other. feature_uid is not part of
    -- the key: see the header above.
    lot_number      text,
    feature_uid     bigint,
    lot_area_m2     double precision NOT NULL,
    -- 0 for a feature that is a point or a line: those are recorded because
    -- they intersect the lot at all, not because they cover any of it.
    overlap_area_m2 double precision NOT NULL,
    -- 100 * overlap_area_m2 / lot_area_m2 — how much of the lot this feature
    -- covers. Sums to ~100 across one areal layer and means nothing summed
    -- across several, since the layers overlap each other freely.
    pct_of_lot      double precision NOT NULL,
    -- The clipped slice, not the whole feature. Bare Geometry rather than a
    -- typed MultiPolygon on both counts: rag.features holds points as well as
    -- polygons, and ST_Intersection of two polygons can legally return a
    -- GeometryCollection along a shared edge.
    geom            geometry(Geometry, 4326),
    loaded_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, cell_partition, lot_uid, source_table, feature_id)
) PARTITION BY LIST (cell_partition);

CREATE INDEX IF NOT EXISTS lot_features_geom_idx
    ON silver.lot_features USING gist (geom);
CREATE INDEX IF NOT EXISTS lot_features_lot_idx
    ON silver.lot_features (lot_uid);
CREATE INDEX IF NOT EXISTS lot_features_lot_number_idx
    ON silver.lot_features (lot_number);
-- The document path: filter to the layer that carries links, then match
-- feature_id against rag.chunks.feature_ids.
CREATE INDEX IF NOT EXISTS lot_features_source_idx
    ON silver.lot_features (source_table, feature_id);
-- The map's per-borough read, which used to be partition pruning.
CREATE INDEX IF NOT EXISTS lot_features_neighborhood_idx
    ON silver.lot_features (neighborhood, scrape_date);

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

    EXECUTE format('ALTER TABLE silver.lot_features OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON silver.lot_features TO %I', ro_role);
    END IF;
END
$$;
