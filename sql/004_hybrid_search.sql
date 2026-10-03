-- requires: rag.chunks.tsv
--
-- Hybrid retrieval: the dense arm and the lexical arm, fused.
--
-- Ranking used to be `ORDER BY embedding <=> query` and nothing else, which is
-- good at "what does the by-law say about X" and bad at the thing a zoning
-- question most often turns on: an exact term. `C01-001` and `C01-007` embed
-- almost identically, so the sheet that phrases the question's words most
-- fluently outranks the sheet that actually governs; an article number, a
-- by-law number and `PIIA` all have the same problem. The tsvector added by
-- the dataplatform (`rag/pgvector.py::_add_search_column`) gives the ranking
-- something exact to fuse with.
--
-- WHY THIS IS A SEPARATE FILE
--
-- `003_spatial_search.sql` is parsed as a whole, and a SQL-language function
-- body is parsed at CREATE time. A database whose `rag.chunks` predates the
-- `tsv` column would fail to create *every* function in that file, including
-- the two that work perfectly well without it. Here the `-- requires:` header
-- above names the column, `scripts/db.py` skips this one file until it exists,
-- and the dense-only path keeps working in the meantime.
--
-- WHY RECIPROCAL RANK FUSION AND NOT A WEIGHTED SCORE
--
-- The two arms are not on comparable scales and cannot be put on one. A cosine
-- similarity from bge-m3 sits in a narrow, corpus-dependent band; `ts_rank_cd`
-- is unbounded and falls with document length. Any weighting between them
-- needs constants nobody can derive, and this corpus moves - Saguenay alone
-- added 6,132 chunks - so a constant tuned today is wrong next month.
--
-- RRF uses only the *rank* each arm assigns, so there is nothing to calibrate.
-- It also degrades correctly when one arm returns nothing, which is not a
-- corner case here: an English question produces an empty French tsquery, and
-- the dense arm simply wins with no special path for it.
--
-- k = 60 is the constant from the original RRF paper and is not sensitive;
-- what it does is stop rank 1 from dominating rank 2 so heavily that the other
-- arm can never contribute.
--
-- A NOTE ON THE FOLD
--
-- Both arms are fed the question with its accents folded away, because the
-- index is built that way: `to_tsvector('french', ...)` does NOT strip
-- accents, and French is routinely typed without them. Measured on this
-- corpus, `marges latérales` matched 4,831 chunks and `marges laterales`
-- matched none. `rag.corpus_tsquery` below is the single place that fold
-- lives for queries, matching `folded()` in the dataplatform for the index.

SET search_path TO rag, public;

-- ---------------------------------------------------------------------------
-- A tsquery that never raises
--
-- `to_tsquery` is strict about its input and a user's question is not; even
-- `plainto_tsquery` will throw on some inputs. `websearch_to_tsquery` parses
-- free text the way a search box does - quoted phrases, OR, leading minus -
-- and is the only one of the three safe to hand a question typed by a person.
--
-- Returns NULL rather than an empty tsquery for a question with no indexable
-- word in it, so the caller can tell "no lexical arm" from "a lexical arm that
-- matched nothing" with an IS NULL test.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rag.corpus_tsquery(query_text text)
RETURNS tsquery
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    -- numnode() rather than a comparison against ''::tsquery: the cast emits
    -- a NOTICE on every empty query, and an English question against a French
    -- index produces one every time. Three lines of log noise per retrieval.
    SELECT CASE
        WHEN numnode(q) = 0 THEN NULL
        ELSE q
    END
      FROM websearch_to_tsquery(
               'french',
               translate(lower(coalesce(query_text, '')),
                         'àâäéèêëîïôöùûüçñ', 'aaaeeeeiioouuucn')
           ) AS q
$$;

COMMENT ON FUNCTION rag.corpus_tsquery(text) IS
    'A question as a French tsquery, accents folded to match the index. NULL '
    'when the question holds no indexable word.';


-- ---------------------------------------------------------------------------
-- The corpus search, hybrid
--
-- Replaces the inline SQL that `hbu_rag_map`'s `queries.search_corpus` used to
-- carry. Behaviour is byte-identical to the dense-only version when
-- `query_text` is NULL, which is what lets the app fall back without a second
-- code path.
--
-- `hnsw.ef_search` is set on the function rather than by the caller: the dense
-- arm asks the index for `match_count * 6` candidates and the WHERE is applied
-- to them afterwards, so filtering by borough is a reason to ask for MORE
-- candidates, not fewer. A function-level SET also makes this non-inlinable,
-- which is wanted here - the LIMIT has to apply inside each arm.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION rag.search_corpus (
    query_embedding vector,
    match_count     integer DEFAULT 5,
    in_neighborhood text    DEFAULT NULL,
    on_scrape_date  date    DEFAULT NULL,
    query_text      text    DEFAULT NULL,
    in_zones        text[]  DEFAULT NULL
)
RETURNS TABLE (
    chunk_id     text,
    doc_id       text,
    url          text,
    title        text,
    source_table text,
    neighborhood text,
    scrape_date  date,
    chunk_text   text,
    page_from    integer,
    page_to      integer,
    similarity   double precision,
    lexical_rank double precision,
    score        double precision
)
LANGUAGE sql STABLE
SET hnsw.ef_search = 200
AS $$
    WITH q AS (
        SELECT rag.corpus_tsquery(query_text) AS tsq
    ),
    dense AS (
        SELECT c.chunk_id,
               c.neighborhood,
               row_number() OVER (ORDER BY c.embedding <=> query_embedding) AS rnk,
               1 - (c.embedding <=> query_embedding) AS similarity
          FROM rag.chunks c
         WHERE (in_neighborhood IS NULL OR c.neighborhood = in_neighborhood)
           AND (on_scrape_date  IS NULL OR c.scrape_date  = on_scrape_date)
           AND (in_zones IS NULL OR c.feature_ids ?| in_zones)
         ORDER BY c.embedding <=> query_embedding
         LIMIT greatest(match_count * 6, 50)
    ),
    lexical AS (
        SELECT c.chunk_id,
               c.neighborhood,
               row_number() OVER (
                   ORDER BY ts_rank_cd(c.tsv, q.tsq, 32) DESC, c.chunk_id
               ) AS rnk,
               ts_rank_cd(c.tsv, q.tsq, 32) AS lexical_rank
          FROM rag.chunks c
         CROSS JOIN q
         WHERE q.tsq IS NOT NULL
           AND c.tsv @@ q.tsq
           AND (in_neighborhood IS NULL OR c.neighborhood = in_neighborhood)
           AND (on_scrape_date  IS NULL OR c.scrape_date  = on_scrape_date)
           AND (in_zones IS NULL OR c.feature_ids ?| in_zones)
         ORDER BY ts_rank_cd(c.tsv, q.tsq, 32) DESC, c.chunk_id
         LIMIT greatest(match_count * 6, 50)
    ),
    -- FULL JOIN on BOTH key columns. Joining on chunk_id alone would fuse the
    -- 33 sheets Quebec City's two arrondissements share - which is the bug the
    -- primary key was widened to (neighborhood, chunk_id) to stop.
    fused AS (
        SELECT coalesce(d.chunk_id, l.chunk_id)         AS chunk_id,
               coalesce(d.neighborhood, l.neighborhood) AS neighborhood,
               d.similarity,
               l.lexical_rank,
               coalesce(1.0 / (60 + d.rnk), 0)
             + coalesce(1.0 / (60 + l.rnk), 0)          AS score
          FROM dense d
          FULL JOIN lexical l
            ON l.chunk_id = d.chunk_id
           AND l.neighborhood = d.neighborhood
    )
    SELECT c.chunk_id,
           c.doc_id,
           c.url,
           c.title,
           c.source_table,
           c.neighborhood,
           c.scrape_date,
           c.text,
           c.page_from,
           c.page_to,
           f.similarity,
           f.lexical_rank,
           f.score
      FROM fused f
      JOIN rag.chunks c
        ON c.chunk_id = f.chunk_id
       AND c.neighborhood = f.neighborhood
     -- Deterministic, and neutral between the arms. Tie-breaking on
     -- similarity DESC NULLS LAST looks harmless and is not: a chunk only the
     -- lexical arm found has no similarity, so it loses every tie to a dense
     -- hit of the same rank - which means the lexical arm could only ever
     -- promote what both arms already had, and never surface what the dense
     -- arm missed. That is most of what it is for.
     ORDER BY f.score DESC, c.chunk_id
     LIMIT match_count;
$$;

COMMENT ON FUNCTION rag.search_corpus(vector, integer, text, date, text, text[]) IS
    'Hybrid corpus search: dense and lexical arms fused by reciprocal rank. '
    'Pass query_text to enable the lexical arm; without it this is the '
    'dense-only search it replaced. in_zones filters on feature_ids, which is '
    'how a named zone code is answered by lookup rather than by resemblance.';


DO $$
DECLARE
    app_role text := 'urban_rag';
    ro_role  text := 'urban_rag_ro';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
        RETURN;
    END IF;
    EXECUTE format('ALTER FUNCTION rag.corpus_tsquery(text) OWNER TO %I', app_role);
    EXECUTE format(
        'ALTER FUNCTION rag.search_corpus(vector, integer, text, date, text, text[])'
        ' OWNER TO %I', app_role);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION rag.corpus_tsquery(text) TO %I', ro_role);
        EXECUTE format(
            'GRANT EXECUTE ON FUNCTION rag.search_corpus(vector, integer, text,'
            ' date, text, text[]) TO %I', ro_role);
    END IF;
END
$$;
