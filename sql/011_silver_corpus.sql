-- silver.document_chunks — the corpus before it is embedded.
--
-- One row per chunk of one PDF the zoning layers link to: the text an
-- embedding is taken of, cut on paragraph boundaries and measured with the
-- embedding model's own tokenizer, plus the provenance that says which
-- document and which map features it came from.
--
-- ---------------------------------------------------------------------------
-- How this differs from rag.chunks, which it does not replace
-- ---------------------------------------------------------------------------
--
-- `rag.chunks` is the *index*: the same rows plus an `embedding vector(N)`
-- column and the HNSW index over it, created and filled by the dataplatform's
-- `document_index` asset (gold) and queried by every reader of the corpus —
-- rag.search_near, rag.search_at_lot, rag.lot_documents, the `urban-rag` CLI.
-- It is upserted on `chunk_id` and pruned to the newest scrape per borough, so
-- it holds what is *current*.
--
-- This table is the silver record of what was chunked, at the grain the
-- pipeline produced it, partitioned by borough and day like everything else in
-- this schema. It holds every scrape date, not only the current one, and it
-- carries no vectors — so "how did the chunking change when the parser
-- changed", "which documents did the 26th cover", "how many tokens is a
-- typical grid" are answerable here without touching the index the query side
-- depends on, and without a partition-by-partition read of the parquet tree.
--
-- The one silver asset with no table of its own is `document_embeddings`, and
-- deliberately: its vectors' home is rag.chunks. A silver copy of them would
-- be a second copy of the only thing in this platform measured in gigabytes,
-- to serve no read. See urban_rag.warehouse.TABLES, which says the same thing
-- next to the registry that omits it.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.document_chunks (
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- Deterministic in the chunker, not a surrogate: same document, same cut,
    -- same id. That is what makes a re-run of a partition an upsert rather
    -- than a duplicate, here and in rag.chunks.
    chunk_id     text NOT NULL,
    doc_id       text NOT NULL,
    chunk_index  integer NOT NULL,
    num_tokens   integer NOT NULL,
    text         text NOT NULL,
    -- The file slug — `Reglement_urbanisme__VSP_REG_ZONE` — not the Spectrum
    -- path the parquet carries in a column of the same name. Every join from
    -- geometry to the corpus matches this against silver.lot_features.
    source_table text NOT NULL,
    url          text NOT NULL,
    title        text,
    -- The ids the scrape saw pointing at this document, as published: a jsonb
    -- array of zone numbers. jsonb rather than the parquet's JSON string
    -- because "which zones cite this document" is a containment query someone
    -- will want, and it reads back as text either way.
    feature_ids  jsonb NOT NULL DEFAULT '[]'::jsonb,
    loaded_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, chunk_id)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS document_chunks_doc_idx
    ON silver.document_chunks (doc_id);
CREATE INDEX IF NOT EXISTS document_chunks_source_idx
    ON silver.document_chunks (source_table);
CREATE INDEX IF NOT EXISTS document_chunks_features_idx
    ON silver.document_chunks USING gin (feature_ids);

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

    EXECUTE format('ALTER TABLE silver.document_chunks OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON silver.document_chunks TO %I', ro_role);
    END IF;
END
$$;
