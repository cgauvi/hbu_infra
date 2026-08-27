-- Partition maintenance for the silver and gold tables.
--
-- Every table in `silver` and `gold` is declaratively partitioned the same
-- way, because every one of them holds the same thing: one borough's snapshot
-- of one day.
--
--     <table>                          PARTITION BY LIST  (neighborhood)
--       <table>__vsmpe                 PARTITION BY RANGE (scrape_date)
--         <table>__vsmpe__202608       one month of it
--
-- Two levels rather than one, and in that order, because the two axes are not
-- the same kind of axis. The borough set is small, closed and named — 17 of
-- them, listed in the dataplatform's `urban_rag.partitions` — so LIST says
-- exactly what it means and a borough's whole history is one subtree an
-- operator can detach or drop. The date axis is open and grows a row every
-- day, so it is RANGE, by month: daily partitions would be ~6 000 tables a
-- year across these tables and buy nothing, since nothing here is ever queried
-- for a single day across all boroughs.
--
-- What this gets a reader is partition pruning on the filter every one of them
-- writes anyway. `WHERE neighborhood = 'VSMPE' AND scrape_date = '2026-08-26'`
-- touches one leaf; without partitioning it is an index scan over every
-- borough-day the table has ever held.
--
-- What it costs the *writer* is the rule this whole design turns on:
--
--     a partitioned table's unique constraint must contain its partition keys.
--
-- So the primary key of every table here is (scrape_date, neighborhood, <the
-- natural key>) — which is not a concession, it is the grain restated, and it
-- is exactly what the dataplatform's upsert conflicts on:
--
--     INSERT INTO silver.neighborhood_streets (...)
--     VALUES (...)
--     ON CONFLICT (scrape_date, neighborhood, cote_rue_id)
--     DO UPDATE SET ...
--
-- See hbu_dataplatform's `urban_rag.warehouse`, which is the only writer.
--
-- ---------------------------------------------------------------------------
-- Why partitions are created on demand rather than declared here
-- ---------------------------------------------------------------------------
--
-- A pre-declared set has to be extended before each new month, by someone who
-- remembers to. A DEFAULT partition would remove that chore and is the wrong
-- fix: rows that land in a default cannot be moved by attaching the partition
-- they belong in — Postgres refuses the ATTACH while the default holds a row
-- that would have gone there — so a default that quietly catches a borough
-- nobody declared is a table that has to be rewritten to repair.
--
-- `warehouse.ensure_partition` is the third option. The pipeline calls it with
-- the (neighborhood, scrape_date) it is about to write, before it writes, and
-- it is two catalog lookups when the leaf already exists. A borough enabled
-- for the first time and the first load of a new month both just work; nothing
-- lands anywhere it cannot be moved out of.
--
-- Owned by the pipeline's role, which is what makes this work at all: it owns
-- the silver and gold schemas, so the partitions it creates through here are
-- its own and inherit the read-only grants 000_roles.sql set up as defaults.

SET search_path TO warehouse, public;

-- ---------------------------------------------------------------------------
-- A partition's name
--
-- Two underscores between the parts, so `neighborhood_streets` + `VSMPE` reads
-- as one table and one borough rather than as an ambiguous run of words. The
-- borough is lowercased and anything outside [a-z0-9_] folded to `_`, since
-- these become identifiers and the borough keys are free text as far as this
-- database is concerned.
--
-- Truncated to 63 bytes because that is what an identifier is; the leading
-- part is the table name, which is the half worth keeping when a name is too
-- long to hold both.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION warehouse.partition_name(base text, suffix text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
AS $$
    SELECT left(base || '__' || regexp_replace(lower(suffix), '[^a-z0-9_]+', '_', 'g'), 63);
$$;

-- ---------------------------------------------------------------------------
-- Create the leaf this (neighborhood, scrape_date) belongs in, if it is new
--
-- Returns the leaf's qualified name, so a caller that wants to log or COPY
-- straight into it can. Idempotent, and safe to call from two runs at once:
-- the `IF ... IS NULL` is the cheap path and the exception block is what
-- covers the race between checking and creating.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION warehouse.ensure_partition(
    parent          regclass,
    in_neighborhood text,
    in_scrape_date  date
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    parent_schema text;
    parent_name   text;
    borough_part  text;
    month_part    text;
    month_start   date := date_trunc('month', in_scrape_date)::date;
    month_end     date := (date_trunc('month', in_scrape_date) + interval '1 month')::date;
BEGIN
    IF in_neighborhood IS NULL OR in_scrape_date IS NULL THEN
        RAISE EXCEPTION
            'ensure_partition(%): neighborhood and scrape_date are the partition '
            'key and neither may be NULL', parent;
    END IF;

    SELECT n.nspname, c.relname
      INTO parent_schema, parent_name
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = parent;

    borough_part := warehouse.partition_name(parent_name, in_neighborhood);
    month_part   := warehouse.partition_name(borough_part, to_char(month_start, 'YYYYMM'));

    -- 1. The borough, itself partitioned by date.
    IF to_regclass(format('%I.%I', parent_schema, borough_part)) IS NULL THEN
        BEGIN
            EXECUTE format(
                'CREATE TABLE %I.%I PARTITION OF %I.%I '
                'FOR VALUES IN (%L) PARTITION BY RANGE (scrape_date)',
                parent_schema, borough_part, parent_schema, parent_name, in_neighborhood
            );
        EXCEPTION
            -- Another session created it between the check and the CREATE.
            -- `invalid_object_definition` is what an overlapping LIST value
            -- raises, which is the same race seen from the other side.
            WHEN duplicate_table OR invalid_object_definition THEN NULL;
        END;
    END IF;

    -- 2. The month inside it.
    IF to_regclass(format('%I.%I', parent_schema, month_part)) IS NULL THEN
        BEGIN
            EXECUTE format(
                'CREATE TABLE %I.%I PARTITION OF %I.%I FOR VALUES FROM (%L) TO (%L)',
                parent_schema, month_part, parent_schema, borough_part,
                month_start, month_end
            );
        EXCEPTION
            WHEN duplicate_table OR invalid_object_definition THEN NULL;
        END;
    END IF;

    RETURN format('%I.%I', parent_schema, month_part);
END
$$;

-- ---------------------------------------------------------------------------
-- What is actually in there
--
-- One row per leaf: which table, which borough, which month, how big. The
-- read `db.py check` prints and the one to run before detaching anything.
-- Leaves only — the borough level is a container and has no storage of its
-- own, so counting it would double every number.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW warehouse.partitions AS
    SELECT parent.relnamespace::regnamespace::text AS table_schema,
           parent.relname                          AS table_name,
           leaf.oid::regclass::text                AS partition,
           pg_get_expr(leaf.relpartbound, leaf.oid) AS bounds,
           COALESCE(stat.n_live_tup, 0)            AS rows,
           pg_total_relation_size(leaf.oid)        AS bytes
      FROM pg_class leaf
      JOIN pg_inherits child   ON child.inhrelid = leaf.oid
      JOIN pg_class borough    ON borough.oid = child.inhparent
      JOIN pg_inherits gparent ON gparent.inhrelid = borough.oid
      JOIN pg_class parent     ON parent.oid = gparent.inhparent
      LEFT JOIN pg_stat_user_tables stat ON stat.relid = leaf.oid
     WHERE parent.relnamespace::regnamespace::text IN ('silver', 'gold')
     ORDER BY 1, 2, 3;

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

    EXECUTE format('ALTER SCHEMA warehouse OWNER TO %I', app_role);
    EXECUTE format(
        'ALTER FUNCTION warehouse.partition_name(text, text) OWNER TO %I', app_role);
    EXECUTE format(
        'ALTER FUNCTION warehouse.ensure_partition(regclass, text, date) OWNER TO %I',
        app_role);
    EXECUTE format('ALTER VIEW warehouse.partitions OWNER TO %I', app_role);

    -- Creating a partition means creating a table, which nothing outside the
    -- pipeline has any business doing. PUBLIC gets EXECUTE on a new function
    -- by default, so this has to be taken back explicitly - and outside the
    -- read-only block below, since it is true whether or not that role exists.
    REVOKE EXECUTE ON FUNCTION
        warehouse.ensure_partition(regclass, text, date) FROM PUBLIC;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        -- USAGE and the view, but not the function: reading which partitions
        -- exist is a reader's business, creating one is not.
        EXECUTE format('GRANT USAGE ON SCHEMA warehouse TO %I', ro_role);
        EXECUTE format('GRANT SELECT ON warehouse.partitions TO %I', ro_role);
    END IF;
END
$$;
