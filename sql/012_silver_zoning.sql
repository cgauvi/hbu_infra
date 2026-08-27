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
-- partitioning and the upsert both primary keys here exist to serve.

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
    max_dwellings                double precision,
    specific_use_area_max_m2     double precision,
    front_margin_min_m           double precision,
    front_margin_max_m           double precision,
    secondary_front_margin_min_m double precision,
    secondary_front_margin_max_m double precision,
    side_margin_min_m            double precision,
    rear_margin_min_m            double precision,
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
-- from both, which is why the zone is in the key and not assumed.
--
-- `lot_uid` rather than `lot_number` in the key, unlike gold.lot_profiles: the
-- upstream join this is built from is keyed on the surrogate, and the number
-- is carried beside it for the readers that need one that survives a reload.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.lot_zoning_envelopes (
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    lot_uid      bigint NOT NULL,
    feature_id   text NOT NULL,
    column_index integer NOT NULL,
    lot_number   text,
    source_table text,
    lot_area_m2  double precision,

    -- -- what the lot faces ------------------------------------------------
    --
    -- Pivoted from silver.lot_frontage, and here rather than only on the
    -- profile because `meets_min_lot_width` below is decided against it: an
    -- envelope is a claim about a *site*, and the site's width is half of it.
    primary_frontage_m    double precision,
    primary_street_name   text,
    primary_cote_rue_id   text,
    secondary_frontage_m  double precision,
    secondary_street_name text,
    secondary_cote_rue_id text,
    num_frontages         integer,
    frontage_buffer_m     double precision,

    -- -- how much of the lot this zone covers ------------------------------
    --
    -- The row exists because the zone covers at least `min_pct_of_lot` of the
    -- parcel; the figure travels so a reader can raise that cutoff without
    -- recomputing anything.
    pct_of_lot      double precision,
    overlap_area_m2 double precision,
    doc_id          text,
    url             text,
    grid_zone       text,

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
    max_dwellings                double precision,
    specific_use_area_max_m2     double precision,
    front_margin_min_m           double precision,
    front_margin_max_m           double precision,
    secondary_front_margin_min_m double precision,
    secondary_front_margin_max_m double precision,
    side_margin_min_m            double precision,
    rear_margin_min_m            double precision,
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
    PRIMARY KEY (scrape_date, neighborhood, lot_uid, feature_id, column_index)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS lot_zoning_envelopes_lot_number_idx
    ON silver.lot_zoning_envelopes (lot_number);
CREATE INDEX IF NOT EXISTS lot_zoning_envelopes_zone_idx
    ON silver.lot_zoning_envelopes (feature_id);
-- "Which lots in this borough can be solved for housing" — the read the whole
-- envelope lineage exists for.
CREATE INDEX IF NOT EXISTS lot_zoning_envelopes_solvable_idx
    ON silver.lot_zoning_envelopes (lot_uid)
    WHERE governs_residential AND solver_ready;

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
