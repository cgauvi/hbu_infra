-- rag.features.source_namespace — the publisher's own unit, named at last.
--
-- 005_silver_lot_features.sql widened this table's uniqueness from
-- (source_table, feature_id, scrape_date) to
-- (source_table, feature_id, neighborhood, scrape_date), because `source_table`
-- is the file slug — `Reglement_urbanisme__VSP_REG_ZONE` — and the slug drops
-- the borough namespace the Spectrum path carries. Every Montreal borough
-- publishes a `VSP_REG_ZONE` and zone numbers restart at C01-001 in each one,
-- so without a fourth column the second borough loaded loses its zones to
-- ON CONFLICT DO NOTHING.
--
-- That fix works, and it works for a reason nobody wrote down: `neighborhood`
-- is 1:1 with the Spectrum namespace that actually distinguishes the two rows.
-- It is standing in for something else. This column names the something else,
-- so that when `neighborhood` stops being a partition key the constraint does
-- not quietly stop meaning anything.
--
--     Montreal      -> the Spectrum namespace, `19_VSMPE`
--     Quebec City   -> `quebec`
--     Saguenay      -> `saguenay`
--
-- Quebec and Saguenay publish **one** zoning layer for the whole municipality
-- and no namespace at all, so theirs is the city. That is weaker than a
-- per-arrondissement qualifier and it is enough: Quebec's zone codes carry the
-- arrondissement in their leading digit and are unique city-wide, and Saguenay
-- is one key by construction. An empty string would be a qualifier that
-- qualifies nothing. See the dataplatform's
-- `urban_rag.partitions.source_namespace_for`, which is where the rule lives.
--
-- ---------------------------------------------------------------------------
-- What this file does NOT do
-- ---------------------------------------------------------------------------
--
-- It does not touch `features_identity_key`. The constraint stays on
-- `neighborhood` until the partition key actually moves, because the two are
-- 1:1 today and swapping them now would be a behaviour change dressed as a
-- rename — on Quebec City it would collapse six arrondissements into one
-- namespace, and the second arrondissement loaded would lose any zone the
-- first had already landed. The swap belongs with the repartition, where its
-- effect can be tested against a partition-sum invariant rather than assumed.
--
-- Done as a separate file rather than an edit to 002_spatial.sql for the
-- reason 005 gives for its own constraint swap: that file's
-- CREATE TABLE IF NOT EXISTS is a no-op on a database that already has the
-- table, so an edit there reaches only databases created after it. 002 carries
-- the column too, for a database created from scratch; this is what reaches
-- the ones that already exist.

SET search_path TO rag, public;

DO $$
BEGIN
    -- Guarded so this file still runs standalone on a database where
    -- 002_spatial.sql has not been applied: `'rag.features'::regclass` is an
    -- error, not a NULL, when the table is not there.
    IF to_regclass('rag.features') IS NULL THEN
        RAISE NOTICE
            'rag.features does not exist - apply 002_spatial.sql, then re-run '
            'this file to add source_namespace';
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'rag'
           AND table_name = 'features'
           AND column_name = 'source_namespace'
    ) THEN
        -- NOT NULL DEFAULT '' rather than nullable: a NULL in a uniqueness
        -- tuple never conflicts with anything, so the day this column joins
        -- `features_identity_key` a nullable one would silently make every
        -- row unique and turn the upsert into an append. The empty string is
        -- what rows loaded before the pipeline started writing the column
        -- carry, and it is visible in a GROUP BY rather than invisible in an
        -- outer join.
        ALTER TABLE rag.features
            ADD COLUMN source_namespace text NOT NULL DEFAULT '';

        RAISE NOTICE
            'rag.features.source_namespace added; rows loaded before this '
            'carry the empty string until their partition is re-materialized';
    END IF;
END
$$;

-- The read this exists for: "which publisher filed this zone number", asked
-- of a layer. Leading with `source_table` for the same reason
-- features_source_partition_idx does - it is always an equality, and the
-- zoning layer is one source_table out of two dozen.
CREATE INDEX IF NOT EXISTS features_source_namespace_idx
    ON rag.features (source_table, source_namespace, scrape_date);
