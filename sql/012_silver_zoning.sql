-- What a zoning grid states, and what it states about a lot — two tables.
--
--   silver.zoning_grid_columns   one row per column of one *grille des usages
--                                et des normes*, parsed out of the PDF the
--                                zoning layer links to. The zone's own grain.
--   silver.lot_zoning_envelopes  the same columns joined to the lots the zone
--                                covers: one row per (lot, grid column), which
--                                is the grain urban_rag.program solves at.
--
-- A borough publishes one grid per zone, printed as a table whose *columns*
-- are the alternatives: a zone permits housing under column 0 and a corner
-- store under column 1, each with its own storey limit, margins and coverage.
-- So a column, not a zone, is what an envelope is built from — and a lot in
-- that zone has one candidate envelope per column.
--
-- Both tables carry `solver_ready` and `solver_error`, which is where the
-- parse either survives contact with the solver or says why it did not. The
-- grids are typeset by each borough from its own template, so a column that
-- prints its storey maximum as "En etage" rather than as a number is normal,
-- not exceptional; keeping the row and recording the reason is what makes the
-- share of a borough that *is* solvable a number anyone can watch.
--
-- New tables: both assets were parquet-only before this file. gold.lot_profiles
-- still picks the envelopes up from the tree as jsonb, at the grain a per-lot
-- read wants; these are for the questions asked at the zone's grain — "which
-- zones permit six storeys", "how much of this borough parsed cleanly" — which
-- a jsonb array on a lot row cannot answer.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql for the
-- partitioning and the upsert both primary keys here exist to serve. The two
-- are on the two axes that file describes: the grid is the zone's and a
-- borough publishes it, so silver.zoning_grid_columns stays on the borough;
-- the envelope is the lot's, so silver.lot_zoning_envelopes is on the cut
-- cell with the rest of the lot chain, and reads the grid of each lot's own
-- borough.

SET search_path TO silver, public;

-- ---------------------------------------------------------------------------
-- The grid, at the zone's grain
--
-- Keyed on (source_table, feature_id, column_index): the layer the zone came
-- from, the zone number it publishes, and which column of its grid this is.
-- `source_table` is in the key rather than assumed because the slug drops the
-- borough namespace and more than one layer can carry a grid.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.zoning_grid_columns (
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    source_table text NOT NULL,
    -- NUMERO_COMPLET on the map — the id the document cites and the id the
    -- grid is headed by.
    feature_id   text NOT NULL,
    column_index integer NOT NULL,
    -- The zone as the *grid* prints it, which is normally feature_id and is
    -- kept separately because "normally" is not "always".
    grid_zone    text,
    doc_id       text,
    url          text,

    -- -- what the column permits -------------------------------------------
    --
    -- The *Categories d'usages* rows. `usages` is the full list as printed;
    -- the four category columns are the same rows split the way a reader asks
    -- about them, and `permits_residential` is the one question asked most.
    usages            jsonb NOT NULL DEFAULT '[]'::jsonb,
    usage_habitation  text,
    usage_commerce    text,
    usage_industrie   text,
    usage_equipements text,
    permits_residential boolean,
    -- Which storeys the usage may occupy — 'tous_les_niveaux', 'rez_de_
    -- chaussee', ... A grid states its storey maximum for the building and
    -- these rows for the usage, and the two are not the same number.
    levels            jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- The storey maximum narrowed by those rows: how many storeys this
    -- column's usage may actually occupy. Not printed anywhere on the grid —
    -- it is what the envelope is built from.
    residential_floors double precision,

    -- -- the norms, as printed ---------------------------------------------
    --
    -- Straight through from the parsed column, in the order the grid prints
    -- them. NULL means the grid did not state it, which is common and is not
    -- the same as zero: a zone with no rear-margin minimum has none.
    floors_min                   double precision,
    floors_max                   double precision,
    height_min_m                 double precision,
    height_max_m                 double precision,
    min_lot_width_m              double precision,
    implantation_mode            text,
    site_coverage_min_pct        double precision,
    site_coverage_max_pct        double precision,
    density_min                  double precision,
    density_max                  double precision,
    -- Quebec City's *Nb de log. à l'hectare min/max*, and NULL on every
    -- Montreal and Saguenay row. A dwelling count per hectare of lot, which
    -- is NOT the floor-area ratio above: the ratio bounds floor area and this
    -- bounds the unit count. A stated 0 is a stated zero — 883 of the city's
    -- zones print 0/0 and all but four authorise no dwelling group at all —
    -- so do not read it as "unstated".
    dwelling_density_min_per_ha  double precision,
    dwelling_density_max_per_ha  double precision,
    max_dwellings                double precision,
    specific_use_area_max_m2     double precision,
    -- Also Quebec City's: *Superficie maximale de plancher*, per building, for
    -- the commerce family. The grid prints it twice — *Vente au détail* and
    -- *Administration* — and this is the tighter of the two, so no split of
    -- the one commerce quantity the solver carries can breach either. Distinct
    -- from specific_use_area_max_m2 above, which is Montreal's *Superficie des
    -- usages spécifiques*.
    commercial_floor_max_m2      double precision,
    front_margin_min_m           double precision,
    front_margin_max_m           double precision,
    secondary_front_margin_min_m double precision,
    secondary_front_margin_max_m double precision,
    side_margin_min_m            double precision,
    rear_margin_min_m            double precision,
    -- The margin a *rear* lot line takes where that line faces a street, for
    -- a by-law that states one apart from the side-on-street margin. Saguenay
    -- is the only publisher here that does - its grid prints *Arrière sur
    -- rue* beside *Latérale sur rue* - so this is NULL on every Montreal and
    -- Quebec City row, where `secondary_front_margin_min_m` governs every
    -- street edge after the first.
    --
    -- Two columns rather than one because which of them applies is a fact
    -- about the *lot* and not about the zone: the second street edge of a
    -- corner lot is a side line and of a through lot is its rear line, and a
    -- zone contains both kinds. The choice is made per lot in sql/015 - see
    -- `secondary_setback_rule` there.
    rear_on_street_margin_min_m  double precision,
    -- Free text as the grid prints it ("3", "1, 4"): a reference into the
    -- borough's own usage numbering, not a list this platform can resolve.
    only_permitted_usages        text,
    excluded_usages              text,

    -- -- whether it can be solved ------------------------------------------
    --
    -- Decided by building the solver's own ZoneColumn and seeing whether it
    -- holds, rather than by re-checking the fields here — a second copy of
    -- that rule would be the copy that goes stale.
    solver_ready boolean NOT NULL DEFAULT false,
    solver_error text,
    -- Everything the parser had to guess at, as an array of notes. The audit
    -- trail for a number that looks wrong.
    parse_notes  jsonb NOT NULL DEFAULT '[]'::jsonb,
    loaded_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, source_table, feature_id, column_index)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS zoning_grid_columns_zone_idx
    ON silver.zoning_grid_columns (feature_id);
-- "How much of this borough parsed cleanly" and "which columns permit
-- housing" are the two reads, and both are a filter on a boolean.
CREATE INDEX IF NOT EXISTS zoning_grid_columns_solvable_idx
    ON silver.zoning_grid_columns (feature_id)
    WHERE solver_ready AND permits_residential;

-- ---------------------------------------------------------------------------
-- The same, joined to the lots the zone covers
--
-- Keyed on (lot_uid, feature_id, column_index): one candidate envelope per
-- (lot, zone, column). A lot straddling two zones legitimately has entries
-- from both, which is why the zone is in the key and not assumed — and since
-- silver.lot_zone_pieces (sql/025) that is more than a key's worth of
-- pedantry: both zones are now solved, over their own ground and against
-- their own street, instead of the best-covered one answering for the parcel.
--
-- `lot_uid` rather than `lot_number` in the key, unlike gold.lot_profiles: the
-- upstream join this is built from is keyed on the surrogate, and the number
-- is carried beside it for the readers that need one that survives a reload.
-- ---------------------------------------------------------------------------

-- The block 004_silver_building_lots.sql explains: a table still partitioned
-- on `neighborhood` is renamed `_by_neighborhood`, its indexes and constraints
-- suffixed `_bn`, so the CREATE below makes the cell-partitioned one beside it.
-- silver.zoning_grid_columns above is not touched: it stays on the borough.
DO $migrate$
DECLARE
    target  regclass := to_regclass('silver.lot_zoning_envelopes');
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
        target, 'lot_zoning_envelopes_by_neighborhood'
    );

    RAISE NOTICE
        'silver.lot_zoning_envelopes was LIST (neighborhood): renamed to '
        'silver.lot_zoning_envelopes_by_neighborhood; suffixed _bn: %',
        array_to_string(renamed, ', ');
END
$migrate$;

CREATE TABLE IF NOT EXISTS silver.lot_zoning_envelopes (
    -- The partition key leads, in the order 003_warehouse.sql explains; the
    -- cell columns are the lot's (028_cell_key.sql) and the borough is the
    -- lot's too — the one whose grid this row was read from.
    scrape_date    date NOT NULL,
    cell_key       text COLLATE "C" NOT NULL,
    cell_partition text COLLATE "C" NOT NULL,
    neighborhood   text NOT NULL,
    lot_uid      bigint NOT NULL,
    feature_id   text NOT NULL,
    column_index integer NOT NULL,
    lot_number   text,
    source_table text,

    -- -- the ground this row is about ---------------------------------------
    --
    -- Both, always, and they are not the same column. `lot_area_m2` is the
    -- whole parcel; `piece_area_m2` is the ground *this zone* governs, from
    -- silver.lot_zone_pieces, and it is what urban_rag.program sizes a
    -- building on. On the great majority of rows one zone covers the parcel
    -- whole and the two are equal — the rows where they differ are the ones
    -- this pair exists for. Lot 1 740 794 is 27 044 m² with 24 596 in H04-072
    -- and 2 440 in C04-083, and the eight storeys H04-072 permits used to be
    -- priced over all of it.
    lot_area_m2   double precision,
    piece_area_m2 double precision,

    -- How many zones cut this lot, where this piece ranks among them by area,
    -- and whether it is the largest. `is_primary_zone` is the row a reader
    -- wanting one answer per parcel takes; `num_lot_zones > 1` is how they
    -- know to expect more than one.
    num_lot_zones   integer,
    zone_rank       integer,
    is_primary_zone boolean,

    -- -- what the piece faces ----------------------------------------------
    --
    -- silver.lot_frontage's edges cut to this piece and re-ranked inside it —
    -- **not** the lot's ranking. `meets_min_lot_width` below is decided
    -- against it: an envelope is a claim about a *site*, and the site's width
    -- is half of it. On a split parcel the pieces can face different streets,
    -- which is exactly the case on 1 740 794: the C04-083 strip has the 19.8 m
    -- of Jarry and the H04-072 remainder behind it has 15.2 m of D'Hérelle.
    primary_frontage_m    double precision,
    primary_street_name   text,
    primary_cote_rue_id   text,
    secondary_frontage_m  double precision,
    secondary_street_name text,
    secondary_cote_rue_id text,
    num_frontages         integer,
    -- The whole parcel's street, for the reader asking how much of it this
    -- piece got.
    lot_frontage_m        double precision,
    frontage_buffer_m     double precision,

    -- -- what already stands on the piece -----------------------------------
    --
    -- The footprint measured on this ground, and the two shares that divide
    -- the lot's assessment between its pieces: `footprint_share` for
    -- everything the building is or earns, `area_share` for the ground. Both
    -- sum to 1 across a lot's pieces. gold.lot_redevelopment_gap is the
    -- reader; see sql/025 for why there are two.
    existing_footprint_m2 double precision,
    area_share            double precision,
    footprint_share       double precision,
    footprint_share_basis text,

    -- -- how much of the lot this zone covers ------------------------------
    --
    -- The row exists because the zone covers at least `min_pct_of_lot` and
    -- `min_overlap_m2` of the parcel, or `min_piece_area_m2` of ground
    -- outright; the three travel so a reader can raise a cutoff without
    -- recomputing anything. They are silver.lot_zone_pieces' decision now,
    -- carried through — see sql/025.
    pct_of_lot        double precision,
    min_pct_of_lot    double precision,
    min_overlap_m2    double precision,
    min_piece_area_m2 double precision,
    doc_id            text,
    url               text,
    grid_zone         text,

    -- -- what the column states --------------------------------------------
    --
    -- The same columns silver.zoning_grid_columns carries, denormalised onto
    -- the lot: this table is read whole, one row at a time, by a solver that
    -- would otherwise join back for every candidate.
    usages            jsonb NOT NULL DEFAULT '[]'::jsonb,
    usage_habitation  text,
    usage_commerce    text,
    usage_industrie   text,
    usage_equipements text,
    permits_residential boolean,
    levels            jsonb NOT NULL DEFAULT '[]'::jsonb,
    residential_floors double precision,

    floors_min                   double precision,
    floors_max                   double precision,
    height_min_m                 double precision,
    height_max_m                 double precision,
    min_lot_width_m              double precision,
    implantation_mode            text,
    site_coverage_min_pct        double precision,
    site_coverage_max_pct        double precision,
    density_min                  double precision,
    density_max                  double precision,
    -- Quebec City's *Nb de log. à l'hectare min/max*, and NULL on every
    -- Montreal and Saguenay row. A dwelling count per hectare of lot, which
    -- is NOT the floor-area ratio above: the ratio bounds floor area and this
    -- bounds the unit count. A stated 0 is a stated zero — 883 of the city's
    -- zones print 0/0 and all but four authorise no dwelling group at all —
    -- so do not read it as "unstated".
    dwelling_density_min_per_ha  double precision,
    dwelling_density_max_per_ha  double precision,
    max_dwellings                double precision,
    specific_use_area_max_m2     double precision,
    -- Also Quebec City's: *Superficie maximale de plancher*, per building, for
    -- the commerce family. The grid prints it twice — *Vente au détail* and
    -- *Administration* — and this is the tighter of the two, so no split of
    -- the one commerce quantity the solver carries can breach either. Distinct
    -- from specific_use_area_max_m2 above, which is Montreal's *Superficie des
    -- usages spécifiques*.
    commercial_floor_max_m2      double precision,
    front_margin_min_m           double precision,
    front_margin_max_m           double precision,
    secondary_front_margin_min_m double precision,
    secondary_front_margin_max_m double precision,
    side_margin_min_m            double precision,
    rear_margin_min_m            double precision,
    -- Saguenay's only; see the note on the same column above.
    rear_on_street_margin_min_m  double precision,
    only_permitted_usages        text,
    excluded_usages              text,

    -- -- and whether it applies here ---------------------------------------
    --
    -- The two columns that exist only at this grain. `meets_min_lot_width`
    -- tests the column's *Largeur du terrain* minimum against the lot's
    -- measured primary frontage — a missing frontage reads as 0, so a column
    -- with a width minimum is excluded rather than assumed. `governs_
    -- residential` marks the one column select_residential_column picks for
    -- this lot: at most one per (lot, zone), and often none.
    meets_min_lot_width boolean,
    governs_residential boolean,
    solver_ready        boolean NOT NULL DEFAULT false,
    solver_error        text,
    parse_notes         jsonb NOT NULL DEFAULT '[]'::jsonb,
    loaded_at           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, cell_partition, lot_uid, feature_id, column_index)
) PARTITION BY LIST (cell_partition);

CREATE INDEX IF NOT EXISTS lot_zoning_envelopes_lot_number_idx
    ON silver.lot_zoning_envelopes (lot_number);
CREATE INDEX IF NOT EXISTS lot_zoning_envelopes_zone_idx
    ON silver.lot_zoning_envelopes (feature_id);
-- "Which lots in this cell can be solved for housing" — the read the whole
-- envelope lineage exists for.
CREATE INDEX IF NOT EXISTS lot_zoning_envelopes_solvable_idx
    ON silver.lot_zoning_envelopes (lot_uid)
    WHERE governs_residential AND solver_ready;
-- The map's per-borough read, which used to be partition pruning.
CREATE INDEX IF NOT EXISTS lot_zoning_envelopes_neighborhood_idx
    ON silver.lot_zoning_envelopes (neighborhood, scrape_date);

-- The two usage families beside Habitation, and the column that governs each
-- of them for this lot — the solver prices all three now, and the developer's
-- choice in gold.lot_highest_best_use is made across the governing column of
-- each family. Written by the same assets; ADD COLUMN IF NOT EXISTS so a
-- database created before they existed picks them up on the next `db.py
-- init`, the way sql/009's later blocks do.
ALTER TABLE silver.zoning_grid_columns
    ADD COLUMN IF NOT EXISTS permits_commercial boolean,
    ADD COLUMN IF NOT EXISTS permits_industrial boolean;

ALTER TABLE silver.lot_zoning_envelopes
    ADD COLUMN IF NOT EXISTS permits_commercial boolean,
    ADD COLUMN IF NOT EXISTS permits_industrial boolean,
    ADD COLUMN IF NOT EXISTS governs_commercial boolean,
    ADD COLUMN IF NOT EXISTS governs_industrial boolean;

-- The other on-street margin, which Saguenay's grid states and Montreal's and
-- Quebec City's do not - see the note on the column in the CREATE above. It is
-- repeated here for the reason the block above gives and one more: CREATE
-- TABLE IF NOT EXISTS leaves an existing table exactly as it found it, so a
-- column added to the body of one reaches a fresh database only. On every
-- database that predates it the column is missing, and the failure surfaces
-- one table downstream - urban_rag.warehouse stages every load in a temp table
-- built `LIKE` its target, so the missing column comes back as
-- `column ... of relation silver_..._load does not exist`.
ALTER TABLE silver.zoning_grid_columns
    ADD COLUMN IF NOT EXISTS rear_on_street_margin_min_m double precision;

ALTER TABLE silver.lot_zoning_envelopes
    ADD COLUMN IF NOT EXISTS rear_on_street_margin_min_m double precision;

DO $$
DECLARE
    app_role text := 'urban_rag';
    ro_role  text := 'urban_rag_ro';
    relation text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
        RAISE NOTICE
            'role % does not exist - apply 000_roles.sql, then re-run this '
            'file to hand over ownership', app_role;
        RETURN;
    END IF;

    FOREACH relation IN ARRAY ARRAY[
        'silver.zoning_grid_columns', 'silver.lot_zoning_envelopes'
    ] LOOP
        EXECUTE format('ALTER TABLE %s OWNER TO %I', relation, app_role);
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
            EXECUTE format('GRANT SELECT ON %s TO %I', relation, ro_role);
        END IF;
    END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- Widening: what the grid states once for the zone, below *Patrimoine*
-- ---------------------------------------------------------------------------
--
-- The parser used to stop reading at the *Patrimoine* row, because everything
-- under it is stated once for the zone rather than per column and its
-- full-width values would have been read as columns. It now reads four of
-- those rows as zone-level text and repeats them on every column of the grid:
--
--   * heritage_sector   - *Secteur d'interet patrimonial*: 'Oui' where the
--                         zone is one (148 of VSMPE's 632 grids), else NULL
--   * piia_sector       - *PIIA (secteur)*: the sector number of the
--                         borough's discretionary PIIA by-law, else NULL
--   * pae               - *PAE*: 'Oui' under a plan d'amenagement d'ensemble
--   * specific_articles - *Articles vises*: the dispositions particulieres of
--                         by-law 01-283 the zone cites, as printed
--
-- They are what gold.lot_investment_opportunities reads to keep a building in
-- a heritage sector out of the teardown and brownfield theses, and to mark a
-- PIIA review on the rest - see that table's header. ADD COLUMN IF NOT EXISTS
-- for the reason the block above uses it: a column added ahead of the code
-- that fills it is left NULL rather than overwritten.
ALTER TABLE silver.zoning_grid_columns
    ADD COLUMN IF NOT EXISTS heritage_sector   text,
    ADD COLUMN IF NOT EXISTS piia_sector       text,
    ADD COLUMN IF NOT EXISTS pae               text,
    ADD COLUMN IF NOT EXISTS specific_articles text;

-- ---------------------------------------------------------------------------
-- Widening: the two norms Quebec City's grid states and Montreal's does not
-- ---------------------------------------------------------------------------
--
-- *Normes de densité* on a Quebec City grid holds two things this schema had
-- no column for, and both were being dropped on the way in:
--
--   * dwelling_density_{min,max}_per_ha - *Nb de log. à l'hectare*. Carried
--     apart from density_min/density_max because those are a floor-area ratio
--     and this is a unit count per hectare; folding one into the other would
--     have multiplied a dwelling count by a lot area and called it floor area.
--     2 592 of the city's zones state the minimum and 985 the maximum.
--   * commercial_floor_max_m2 - *Superficie maximale de plancher* for the
--     commerce family, per building: the tighter of the grid's *Vente au
--     détail* and *Administration* ceilings, which differ on 2 845 zones.
--
-- Repeated here as ALTERs for the reason the rear_on_street_margin_min_m block
-- above gives: CREATE TABLE IF NOT EXISTS leaves an existing table as it found
-- it, so a column added to the body of one reaches a fresh database only, and
-- on hbu-dev the failure surfaces as `column ... of relation
-- silver_..._load does not exist`.
--
-- A column added ahead of the data is NULL, not wrong. Every row written
-- before this is NULL here and nothing backfills it: re-materialize the
-- partition's zoning_grid_columns and lot_zoning_envelopes to fill them, and
-- re-solve lot_development_programs, since the solver now reads all three.
ALTER TABLE silver.zoning_grid_columns
    ADD COLUMN IF NOT EXISTS dwelling_density_min_per_ha double precision,
    ADD COLUMN IF NOT EXISTS dwelling_density_max_per_ha double precision,
    ADD COLUMN IF NOT EXISTS commercial_floor_max_m2     double precision;

ALTER TABLE silver.lot_zoning_envelopes
    ADD COLUMN IF NOT EXISTS dwelling_density_min_per_ha double precision,
    ADD COLUMN IF NOT EXISTS dwelling_density_max_per_ha double precision,
    ADD COLUMN IF NOT EXISTS commercial_floor_max_m2     double precision;
