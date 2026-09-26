-- Partition maintenance for the silver and gold tables.
--
-- Every table in `silver` and `gold` is declaratively partitioned the same
-- way, because every one of them holds the same thing: one partition's
-- snapshot of one month.
--
--     <table>                          PARTITION BY LIST  (<spatial column>)
--       <table>__vsmpe                 PARTITION BY RANGE (scrape_date)
--         <table>__vsmpe__202608       one month of it
--
-- Which spatial column leads is the table's *axis*, and there are two. The
-- lot chain - every table whose rows have a lot, a street side or an address
-- point to be placed by - is `LIST (cell_partition)`: a cell of the tile cut,
-- a quadkey such as `0302303330102`, ground that cannot be redrawn and holds
-- about one run's worth of lots wherever it is. What a *publisher* bounds -
-- the CMHC and C&W tables, the zoning grid, the roll, the corpus - is
-- `LIST (neighborhood)`, the borough it was published for. The dataplatform's
-- `urban_rag.warehouse.Axis` names which is which; the functions here do not
-- care, because a LIST child is created against whatever the parent is
-- partitioned by.
--
-- Two levels rather than one, and in that order, because the two axes are not
-- the same kind of axis. The spatial set is small, closed and named - a few
-- dozen cells, listed in the dataplatform's `urban_rag.tile_cut`, or the
-- boroughs in `urban_rag.partitions` - so LIST says exactly what it means and
-- a partition's whole history is one subtree an operator can detach or drop.
-- The date axis is open and grows a row every day, so it is RANGE, by month:
-- daily partitions would be ~6 000 tables a year across these tables and buy
-- nothing, since nothing here is ever queried for a single day everywhere.
--
-- What this gets a reader is partition pruning on the filter every one of them
-- writes anyway. `WHERE cell_partition = '0302303330102' AND scrape_date =
-- '2026-08-26'` touches one leaf; without partitioning it is an index scan
-- over every partition-month the table has ever held.
--
-- What it costs the *writer* is the rule this whole design turns on:
--
--     a partitioned table's unique constraint must contain its partition keys.
--
-- So the primary key of every table here is (scrape_date, <spatial column>,
-- <the natural key>) — which is not a concession, it is the grain restated,
-- and it is exactly what the dataplatform's upsert conflicts on:
--
--     INSERT INTO silver.lot_frontage (...)
--     VALUES (...)
--     ON CONFLICT (scrape_date, cell_partition, lot_uid, cote_rue_id)
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
-- the (partition, scrape_date) it is about to write, before it writes, and
-- it is two catalog lookups when the leaf already exists. A borough or a cell
-- written for the first time and the first load of a new month both just
-- work; nothing lands anywhere it cannot be moved out of.
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
-- partition value is lowercased and anything outside [a-z0-9_] folded to `_`,
-- since these become identifiers and the borough keys are free text as far as
-- this database is concerned. A cut cell is digits 0-3 and passes untouched.
--
-- Truncated to 63 bytes because that is what an identifier is; the leading
-- part is the table name, which is the half worth keeping when a name is too
-- long to hold both. Nothing here reaches it: the longest table name plus a
-- 14-digit cell plus a month is 52.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION warehouse.partition_name(base text, suffix text)
RETURNS text
LANGUAGE sql IMMUTABLE STRICT
AS $$
    SELECT left(base || '__' || regexp_replace(lower(suffix), '[^a-z0-9_]+', '_', 'g'), 63);
$$;

-- ---------------------------------------------------------------------------
-- Create the leaf this (partition, scrape_date) belongs in, if it is new
--
-- `in_partition` is the LIST value - a borough key or a cut cell, whichever
-- the parent is partitioned on; this function never looks at the column's
-- name. Returns the leaf's qualified name, so a caller that wants to log or
-- COPY straight into it can. Idempotent, and safe to call from two runs at
-- once: the `IF ... IS NULL` is the cheap path and the exception block is
-- what covers the race between checking and creating.
--
-- Dropped before it is created because the parameter was renamed from
-- `in_neighborhood`, and `CREATE OR REPLACE` refuses to rename a parameter -
-- it would abort `db init` on every database created before the tile axis.
-- Nothing depends on the function (it is only called), and the ownership and
-- the REVOKE below are re-applied on every run, so the drop costs nothing.
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS warehouse.ensure_partition(regclass, text, date);

CREATE OR REPLACE FUNCTION warehouse.ensure_partition(
    parent          regclass,
    in_partition    text,
    in_scrape_date  date
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    parent_schema text;
    parent_name   text;
    list_part     text;
    month_part    text;
    month_start   date := date_trunc('month', in_scrape_date)::date;
    month_end     date := (date_trunc('month', in_scrape_date) + interval '1 month')::date;
BEGIN
    IF in_partition IS NULL OR in_scrape_date IS NULL THEN
        RAISE EXCEPTION
            'ensure_partition(%): the partition value and scrape_date are the '
            'partition key and neither may be NULL', parent;
    END IF;

    SELECT n.nspname, c.relname
      INTO parent_schema, parent_name
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.oid = parent;

    list_part  := warehouse.partition_name(parent_name, in_partition);
    month_part := warehouse.partition_name(list_part, to_char(month_start, 'YYYYMM'));

    -- 1. The LIST child - a borough or a cell - itself partitioned by date.
    IF to_regclass(format('%I.%I', parent_schema, list_part)) IS NULL THEN
        BEGIN
            EXECUTE format(
                'CREATE TABLE %I.%I PARTITION OF %I.%I '
                'FOR VALUES IN (%L) PARTITION BY RANGE (scrape_date)',
                parent_schema, list_part, parent_schema, parent_name, in_partition
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
                parent_schema, month_part, parent_schema, list_part,
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
-- One row per leaf: which table, which partition, which month, how big. The
-- read `db.py check` prints and the one to run before detaching anything.
-- Leaves only — the LIST level is a container and has no storage of its own,
-- so counting it would double every number.
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
      JOIN pg_class list_child ON list_child.oid = child.inhparent
      JOIN pg_inherits gparent ON gparent.inhrelid = list_child.oid
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
