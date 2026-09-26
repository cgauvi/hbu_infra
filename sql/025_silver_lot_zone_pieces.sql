-- silver.lot_zone_pieces — the piece of a lot that one zone governs, as a site
-- in its own right. One row per (lot, zone).
--
-- No `-- requires:` header, for the reason 015 gives: the table declares no
-- foreign key, so it can be created on a database holding neither
-- silver.lot_features nor silver.lot_frontage, and the check that those have
-- landed belongs in compute_lot_zone_pieces where it can name every file at
-- once.
--
-- ---------------------------------------------------------------------------
-- Why a lot is not always one site
-- ---------------------------------------------------------------------------
--
-- A zoning boundary does not have to follow a lot line, and on a large parcel
-- it usually does not. Lot 1 740 794 in Villeray-Saint-Michel-Parc-Extension
-- is 27 044 m² and the case to picture: 24 596 m² of it sits in H04-072, which
-- permits H.7 to eight storeys, and 2 440 m² sits in C04-083, which permits
-- C.4 and H to six. Those are two different sites. They face two different
-- streets — the commercial strip is the piece that fronts Jarry, and the
-- residential remainder behind it fronts D'Hérelle — they are governed by two
-- different grids, and what may profitably be built on each is a separate
-- question with a separate answer.
--
-- Before this table the platform answered it once. silver.lot_zoning_envelopes
-- has always written a row per (lot, zone, column), but every row carried the
-- *whole* lot's area and the *whole* lot's frontage, and hbu.governing_zone
-- then kept only the best-covered zone and discarded the rest. So the eight
-- storeys of H04-072 were priced over all 27 044 m² — 2 440 m² of which it does
-- not govern — and the C.4 rights on Jarry were not priced at all. Over VSMPE
-- that is 1 861 lots carrying more than one zone, 628 of them with two or more
-- pieces above 500 m², and 121 ha of land priced under a grid that does not
-- govern it.
--
-- This table is the fix, and the shape of the fix is that the *piece* becomes
-- the unit of work. Everything downstream — the envelope, the setbacks, the
-- CP-SAT solve, the redevelopment gap, the IRR, the map — keys on (lot, zone)
-- and reads the piece's own area, its own frontage and its own share of what
-- already stands. The lot is still there: `lot_number` groups the pieces back
-- together, `num_lot_zones` says how many there are, and `is_primary_zone`
-- marks the one a reader who wants a single row per lot should take.
--
-- ---------------------------------------------------------------------------
-- The frontage is the piece's, and that is most of the point
-- ---------------------------------------------------------------------------
--
-- silver.lot_frontage measures the street a *lot* faces, ranked longest first.
-- A piece of that lot faces only the part of that edge lying on its own
-- boundary, and which street that is can differ from the lot's answer: on
-- 1 740 794 the lot's rank-1 frontage is 19.8 m of Jarry, and it belongs
-- entirely to the 2 440 m² commercial piece. The residential piece behind it
-- has 15.2 m of D'Hérelle and no Jarry at all.
--
-- So each frontage linestring is intersected with the piece — with a
-- quarter-metre tolerance, because the clip and the boundary are two derived
-- geometries rather than the topologically shared edge silver.lot_frontage
-- measures against — and the surviving lengths are re-ranked within the piece.
-- `primary_*` is the piece's own rank 1 and `secondary_*` its rank 2, which is
-- exactly the pair silver.lot_zoning_envelopes reads and hands the solver as
-- *Largeur du terrain* and *Avant secondaire*.
--
-- A piece with no street of its own is a real answer and not a gap: it is an
-- interior remnant, and 0 m is what holds it to the columns its grid prints no
-- width minimum for. It is not a new gap either — measured over the pieces of
-- lots that have any frontage row at all, 38 of the 158 pieces above 500 m²
-- come out landlocked, and every piece of a lot silver.lot_frontage could not
-- measure was already reading 0 m before this table existed.
--
-- ---------------------------------------------------------------------------
-- Two allocators, because the roll is per lot and the answer is per piece
-- ---------------------------------------------------------------------------
--
-- silver.lot_assessment_comparables describes the lot: one floor area, one
-- dwelling count, one NOI, one assessed value. gold.lot_redevelopment_gap
-- subtracts that from the program, and the program is now per piece — so the
-- roll has to be split, and how it is split is a judgement this table makes
-- once and records on the row rather than leaving to each reader.
--
--   footprint_share  what share of the lot's *building* stands on this piece,
--                    measured by clipping silver.building_lot_intersections'
--                    own lot-clipped footprints to the piece. This is what
--                    divides everything the building is or earns: floor area,
--                    dwellings, storeys, gross income, NOI, building value.
--                    A piece with nothing standing on it reads 0 and is
--                    correctly treated as vacant land with the whole envelope
--                    still to build.
--
--   area_share       piece_area_m2 / lot_area_m2. This divides what belongs to
--                    the *ground* rather than to the building — land value,
--                    and the assessed total where the two cannot be told
--                    apart.
--
-- Pro-rating the building by area would have been simpler and is wrong in the
-- ordinary case: a corner commercial strip is a tenth of the parcel and
-- carries the whole of the retail block standing on it, and charging it a
-- tenth of that building would report nine tenths of a teardown that is not
-- there.
--
-- Where a lot carries no measured footprint at all — the buildings layer did
-- not reach it, or the parcel is genuinely vacant — `footprint_share` falls
-- back to `area_share` so a null never propagates into a gap, and
-- `footprint_share_basis` says which of the two the row used.
--
-- Computed by hbu_dataplatform (urban_rag.postgis.compute_lot_zone_pieces)
-- one cut cell at a time, once the cell's silver.lot_features,
-- silver.lot_frontage and silver.building_lot_intersections rows have
-- landed, and written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO silver, public;

-- The block 004_silver_building_lots.sql explains: a table still partitioned
-- on `neighborhood` is renamed `_by_neighborhood`, its indexes and constraints
-- suffixed `_bn`, so the CREATE below makes the cell-partitioned one beside it.
DO $migrate$
DECLARE
    target  regclass := to_regclass('silver.lot_zone_pieces');
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
        target, 'lot_zone_pieces_by_neighborhood'
    );

    RAISE NOTICE
        'silver.lot_zone_pieces was LIST (neighborhood): renamed to '
        'silver.lot_zone_pieces_by_neighborhood; suffixed _bn: %',
        array_to_string(renamed, ', ');
END
$migrate$;

CREATE TABLE IF NOT EXISTS silver.lot_zone_pieces (
    -- The partition key leads, in the order 003_warehouse.sql explains; the
    -- cell columns are the lot's (028_cell_key.sql) and the borough is the
    -- lot's too, carried for the map's per-borough reads.
    scrape_date    date NOT NULL,
    cell_key       text COLLATE "C" NOT NULL,
    cell_partition text COLLATE "C" NOT NULL,
    neighborhood   text NOT NULL,
    -- One row per (lot, zone). Narrower than silver.lot_zoning_envelopes'
    -- (lot, zone, column) on purpose: a piece is a piece of ground, and the
    -- several columns of one grid all describe the same ground.
    lot_uid      bigint NOT NULL,
    feature_id   text NOT NULL,
    -- The key that survives a reload, carried for every join that cannot use
    -- lot_uid: it is a bigserial load_lots mints again on every load.
    lot_number   text,
    source_table text,

    -- -- the ground --------------------------------------------------------
    --
    -- The whole parcel, carried so a reader holding one piece knows what it is
    -- a piece of without a join back.
    lot_area_m2   double precision,
    -- The piece itself. This is the area the solver sizes a building on, and
    -- the column that replaces lot_area_m2 everywhere downstream.
    piece_area_m2 double precision NOT NULL,
    pct_of_lot    double precision,

    -- How many zones this lot is cut into, and where this piece ranks among
    -- them by area. `is_primary_zone` marks rank 1 — the zone that used to be
    -- the only one solved, and the row a reader wanting one answer per lot
    -- should still take.
    num_lot_zones   integer NOT NULL,
    zone_rank       integer NOT NULL,
    is_primary_zone boolean NOT NULL,

    -- -- the street this piece faces ---------------------------------------
    --
    -- silver.lot_frontage's edges, clipped to this piece and re-ranked within
    -- it. Not the lot's ranking: see the header on 1 740 794, where the lot's
    -- rank 1 belongs entirely to one of its two pieces.
    primary_frontage_m    double precision,
    primary_street_name   text,
    primary_cote_rue_id   text,
    secondary_frontage_m  double precision,
    secondary_street_name text,
    secondary_cote_rue_id text,
    -- Every street this piece touches, including the ones past rank 2 that get
    -- no columns of their own — so a piece facing three streets is visible as
    -- one rather than silently the same as a corner.
    num_frontages         integer NOT NULL,
    -- The lot's own total, for the reader asking how much of its parcel's
    -- street this piece got.
    lot_frontage_m        double precision,
    -- FRONTAGE_NO_BUFFER on an exact edge, the reach that found it on an
    -- estimate — silver.lot_frontage's own column, carried through as the max
    -- over the edges that reached this piece.
    frontage_buffer_m     double precision,

    -- -- what already stands on it -----------------------------------------
    --
    -- silver.building_lot_intersections' lot-clipped footprints, clipped again
    -- to this piece. `lot_footprint_m2` is the same measure over the whole
    -- parcel, carried so the share below can be read back.
    existing_footprint_m2 double precision NOT NULL,
    lot_footprint_m2      double precision,
    num_buildings         integer NOT NULL,

    -- The two allocators, argued in the header. Both are in [0, 1] and both
    -- sum to 1 across a lot's pieces.
    area_share            double precision NOT NULL,
    footprint_share       double precision NOT NULL,
    -- 'footprint' where the lot carried a measured building and the share is
    -- the footprint's, 'area' where it did not and the share fell back to the
    -- ground. A borough where this reads 'area' on many rows is one whose
    -- buildings layer did not land, which is a fact worth seeing rather than
    -- inferring from a suspiciously even split.
    footprint_share_basis text NOT NULL,

    -- -- what it was computed with -----------------------------------------
    --
    -- The house rule silver.lot_frontage.buffer_m and
    -- silver.lot_buildable_setbacks.max_sin follow: a threshold that decides
    -- what a number means travels on every row carrying that number.
    --
    -- How much of a lot a zone had to cover to get a row here at all. The
    -- first two are silver.lot_zoning_envelopes' own cutoffs, restated on the
    -- row; the third is the absolute floor that keeps a percentage from
    -- discarding a real site on a very large parcel.
    min_pct_of_lot    double precision NOT NULL,
    min_overlap_m2    double precision NOT NULL,
    min_piece_area_m2 double precision NOT NULL,
    -- How far off the piece's boundary a frontage linestring counted as lying
    -- on it.
    edge_tolerance_m  double precision NOT NULL,

    -- The piece itself. MultiPolygon because a zone can cut a lot into two
    -- disjoint parts — a strip along a street and a corner behind it are one
    -- zone and two polygons — and typing it as Polygon would reject rows that
    -- are perfectly correct. This is the geometry the map draws: one feature
    -- per piece, not one per lot.
    geom      geometry(MultiPolygon, 4326),
    loaded_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, cell_partition, lot_uid, feature_id)
) PARTITION BY LIST (cell_partition);

CREATE INDEX IF NOT EXISTS lot_zone_pieces_geom_idx
    ON silver.lot_zone_pieces USING gist (geom);
CREATE INDEX IF NOT EXISTS lot_zone_pieces_lot_number_idx
    ON silver.lot_zone_pieces (lot_number);
CREATE INDEX IF NOT EXISTS lot_zone_pieces_zone_idx
    ON silver.lot_zone_pieces (feature_id);
-- "One row per lot" is still a read this table has to serve cheaply — every
-- caller that wants the parcel's headline answer takes the primary piece.
CREATE INDEX IF NOT EXISTS lot_zone_pieces_primary_idx
    ON silver.lot_zone_pieces (lot_uid)
    WHERE is_primary_zone;
-- "Which lots are actually split" — the question this table exists for.
CREATE INDEX IF NOT EXISTS lot_zone_pieces_split_idx
    ON silver.lot_zone_pieces (neighborhood, scrape_date)
    WHERE num_lot_zones > 1;
-- The map's per-borough read, which used to be partition pruning.
CREATE INDEX IF NOT EXISTS lot_zone_pieces_neighborhood_idx
    ON silver.lot_zone_pieces (neighborhood, scrape_date);
-- The same reads by ground rather than by borough: a prefix range on the
-- lot's cell_key is a range over contiguous ground (028_cell_key.sql).
CREATE INDEX IF NOT EXISTS lot_zone_pieces_cell_key_idx
    ON silver.lot_zone_pieces (cell_key);

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
        'ALTER TABLE silver.lot_zone_pieces OWNER TO %I', app_role
    );

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON silver.lot_zone_pieces TO %I', ro_role
        );
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Re-keying the tables downstream, for a database that already holds them
-- ---------------------------------------------------------------------------
--
-- Everything above creates a new table, so `CREATE TABLE IF NOT EXISTS` does
-- the whole job on a fresh database. On one that already holds the zoning and
-- gold tables it does nothing for them: their headers now declare the piece
-- grain and their DDL is skipped, so the columns and the primary key have to
-- be migrated here.
--
-- This block lives in 025 rather than in each of the six files for one
-- reason: they run in name order, so a re-key written in 012 would execute
-- before this file created the table it re-keys against, and a reader looking
-- for "when did the grain change" would have to find six copies of the answer.
-- It is idempotent and safe to re-run.
--
-- **The rows already in these tables were computed under the old grain**, and
-- this does not pretend otherwise. Every one of them was solved over its whole
-- parcel; on a split lot that is the wrong area under one of two grids. They
-- are carried rather than deleted — `computed_at` says when each was written —
-- and re-materializing a partition replaces it entirely. `num_lot_zones` is
-- left NULL on them, which is how a reader tells a migrated row from a
-- recomputed one.

DO $migrate$
DECLARE
    -- One entry per table this grain change touches: the table, and the
    -- columns it gains. Data rather than a run of ALTER statements, because
    -- **every one of these tables can legitimately be absent**. The gold
    -- tables are applied to a database only once the assets that fill them
    -- exist, and hbu_dataplatform's integration tests apply four of these
    -- files and none of the others - so a bare ALTER would fail the whole
    -- init on a database that is simply earlier in its life than this file.
    -- The loop below checks `to_regclass` and skips.
    widenings constant text[][] := ARRAY[
        ['silver.lot_zoning_envelopes',
         'piece_area_m2 double precision,
          num_lot_zones integer,
          zone_rank integer,
          is_primary_zone boolean,
          lot_frontage_m double precision,
          existing_footprint_m2 double precision,
          area_share double precision,
          footprint_share double precision,
          footprint_share_basis text,
          min_pct_of_lot double precision,
          min_overlap_m2 double precision,
          min_piece_area_m2 double precision'],
        ['silver.lot_buildable_setbacks',
         'piece_area_m2 double precision,
          num_lot_zones integer'],
        ['silver.lot_development_programs',
         'piece_area_m2 double precision,
          num_lot_zones integer,
          is_primary_zone boolean,
          primary_street_name text'],
        ['gold.lot_highest_best_use',
         'piece_area_m2 double precision,
          num_lot_zones integer,
          zone_rank integer,
          is_primary_zone boolean,
          primary_street_name text,
          secondary_frontage_m double precision,
          secondary_street_name text,
          num_frontages integer,
          existing_footprint_m2 double precision,
          area_share double precision,
          footprint_share double precision,
          footprint_share_basis text'],
        ['gold.lot_redevelopment_gap',
         'feature_id text,
          piece_area_m2 double precision,
          num_lot_zones integer,
          is_primary_zone boolean,
          existing_footprint_m2 double precision,
          area_share double precision,
          footprint_share double precision,
          footprint_share_basis text'],
        ['gold.lot_investment_opportunities',
         'feature_id text,
          piece_area_m2 double precision,
          num_lot_zones integer,
          is_primary_zone boolean']
    ];
    -- The tables whose primary key gains the zone, in the order they are
    -- keyed. gold.lot_building_massing and gold.lot_surface_parking carry
    -- `feature_id` already and only need the key changed, which is why they
    -- are here and not above.
    rekeyed constant text[] := ARRAY[
        'gold.lot_highest_best_use',
        'gold.lot_redevelopment_gap',
        'gold.lot_investment_opportunities',
        'gold.lot_building_massing',
        'gold.lot_surface_parking'
    ];
    target text;
    columns text;
    constraint_name text;
    keyed boolean;
BEGIN
    -- 1. The piece columns, on each table that reads them and exists.
    FOR i IN 1 .. array_length(widenings, 1) LOOP
        target  := widenings[i][1];
        columns := widenings[i][2];
        CONTINUE WHEN to_regclass(target) IS NULL;
        EXECUTE format(
            'ALTER TABLE %s ADD COLUMN IF NOT EXISTS %s',
            target,
            replace(regexp_replace(columns, '\s+', ' ', 'g'),
                    ', ', ', ADD COLUMN IF NOT EXISTS ')
        );
    END LOOP;

    -- 2. Backfill the zone on the two tables that never carried one. Both were
    --    one row per lot, so gold.lot_highest_best_use has exactly one zone to
    --    give each of them and the join is unambiguous.
    IF to_regclass('gold.lot_highest_best_use') IS NOT NULL THEN
        IF to_regclass('gold.lot_redevelopment_gap') IS NOT NULL THEN
            UPDATE gold.lot_redevelopment_gap g
               SET feature_id = h.feature_id
              FROM gold.lot_highest_best_use h
             WHERE g.feature_id IS NULL
               AND h.lot_uid = g.lot_uid
               AND h.neighborhood = g.neighborhood
               AND h.scrape_date = g.scrape_date;
        END IF;
        IF to_regclass('gold.lot_investment_opportunities') IS NOT NULL THEN
            UPDATE gold.lot_investment_opportunities o
               SET feature_id = h.feature_id
              FROM gold.lot_highest_best_use h
             WHERE o.feature_id IS NULL
               AND h.lot_uid = o.lot_uid
               AND h.neighborhood = o.neighborhood
               AND h.scrape_date = o.scrape_date;
        END IF;
    END IF;

    -- 3. A migrated row is the whole of its lot by definition — that is what
    --    the old grain meant — so it is its own primary piece, and a zone it
    --    never recorded reads as a dash rather than a plausible zone number,
    --    which would make the row look answered by a grid it never saw.
    --    num_lot_zones is deliberately left NULL: it is what tells a reader
    --    this row was migrated rather than recomputed.
    FOREACH target IN ARRAY rekeyed LOOP
        CONTINUE WHEN to_regclass(target) IS NULL;
        EXECUTE format(
            'UPDATE %s SET feature_id = ''-'' WHERE feature_id IS NULL', target
        );
    END LOOP;
    FOREACH target IN ARRAY ARRAY[
        'silver.lot_zoning_envelopes',
        'gold.lot_highest_best_use',
        'gold.lot_redevelopment_gap',
        'gold.lot_investment_opportunities'
    ] LOOP
        CONTINUE WHEN to_regclass(target) IS NULL;
        EXECUTE format(
            'UPDATE %s SET is_primary_zone = true WHERE is_primary_zone IS NULL',
            target
        );
    END LOOP;

    -- 4. The key itself. Dropped by the name CREATE TABLE generated and added
    --    back with the zone in it. On a LIST-partitioned parent both cascade
    --    to every partition, which is why this is one statement per table
    --    rather than one per leaf.
    FOREACH target IN ARRAY rekeyed LOOP
        CONTINUE WHEN to_regclass(target) IS NULL;

        SELECT conname INTO constraint_name
          FROM pg_constraint
         WHERE conrelid = target::regclass AND contype = 'p';
        CONTINUE WHEN constraint_name IS NULL;

        -- Already re-keyed by an earlier run of this file.
        SELECT EXISTS (
            SELECT 1
              FROM pg_constraint c
              JOIN pg_attribute a
                ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
             WHERE c.conname = constraint_name
               AND c.conrelid = target::regclass
               AND a.attname = 'feature_id'
        ) INTO keyed;
        CONTINUE WHEN keyed;

        EXECUTE format(
            'ALTER TABLE %s ALTER COLUMN feature_id SET NOT NULL', target
        );
        EXECUTE format(
            'ALTER TABLE %s DROP CONSTRAINT %I', target, constraint_name
        );
        EXECUTE format(
            'ALTER TABLE %s ADD PRIMARY KEY '
            '(scrape_date, neighborhood, lot_uid, feature_id)',
            target
        );
        RAISE NOTICE
            're-keyed % on (scrape_date, neighborhood, lot_uid, feature_id)',
            target;
    END LOOP;

    -- 5. The two indexes sql/018 declares beside its new key. Here rather than
    --    there because that file runs first, and on an existing database its
    --    `CREATE TABLE IF NOT EXISTS` does nothing — so the columns these are
    --    over do not exist until step 1 above adds them.
    IF to_regclass('gold.lot_highest_best_use') IS NOT NULL THEN
        CREATE INDEX IF NOT EXISTS lot_highest_best_use_primary_idx
            ON gold.lot_highest_best_use (lot_uid)
            WHERE is_primary_zone;
        CREATE INDEX IF NOT EXISTS lot_highest_best_use_split_idx
            ON gold.lot_highest_best_use (lot_number)
            WHERE num_lot_zones > 1;
    END IF;
END
$migrate$;

