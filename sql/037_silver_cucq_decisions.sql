-- silver.cucq_decisions — what the Commission d'urbanisme et de conservation
-- de Québec decided, one row per permit request.
--
-- The CUCQ is the body that decides a permit in Quebec City's heritage
-- sectors and, since the 2023 demolition by-law (R.V.Q. 3117), every
-- demolition of a building in them. Where a conseil de quartier is consulted
-- about a zoning amendment (032), the Commission rules on one address at a
-- time, and files with each sitting's minutes the list of what it approved,
-- approved conditionally and refused. That list is this table: the record of
-- per-building decisions the council corpus does not hold.
--
-- One row per *decision*: an entry of a regular sitting's annexed list
-- (sitting_kind 'regular'), or one hearing item of a sitting of the
-- Commission's comité de démolition (sitting_kind 'demolition_committee'),
-- read by regular expression out of the flattened PDF by the dataplatform's
-- cities.quebec_city.cucq.minutes with nothing guessed - a field the pattern
-- did not reach is null, and `parse_notes` says what was expected and not
-- found. `doc_id` is the minute's (sha256(url)[:16], the same id
-- bronze/cucq_minutes carries) and `item_index` the decision's place in it.
--
-- ---------------------------------------------------------------------------
-- The borough is the address's
-- ---------------------------------------------------------------------------
--
-- The Commission is one body for the whole city and its minutes name no
-- arrondissement. A row's `neighborhood` is the borough of the door its
-- address was matched to in silver.lot_addresses - the civic number and the
-- street folded by silver.street_core on both sides, the same join 035 makes
-- for a council item's address - and `lot_number` and `match_basis`
-- ('address', or 'address_cardinal' when the minute dropped Est/Ouest and the
-- first such door was taken) say how. A decision whose address reached no
-- loaded door is in the dataplatform's parquet and not here: the bronze tree
-- keeps every decision, this table holds the ones that have ground under
-- them, and a borough whose addresses are not loaded yet holds none.
--
-- Written through hbu_dataplatform.core.warehouse — see 003_warehouse.sql —
-- by publish_by_neighborhood: one city-wide date partition publishes every
-- borough it placed a decision in, the way assessment_units is published.
--
-- ---------------------------------------------------------------------------
-- The corpus
-- ---------------------------------------------------------------------------
--
-- Each decision is also one document of the retrieval corpus: its paragraph
-- is chunked under `chunk_doc_id` into silver.document_chunks (011) with
-- source_table 'cucq_minutes' or 'cucq_demolition_committee', and the
-- chunks' doc_id is that column - so a decision's passages are
--
--     SELECT * FROM silver.document_chunks WHERE doc_id = d.chunk_doc_id
--
-- and no citations column is needed. The embeddings and the rag.chunks load
-- are the two steps the council corpus takes next and this one does not yet.

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.cucq_decisions (
    scrape_date    date NOT NULL,
    neighborhood   text NOT NULL,
    doc_id         text NOT NULL,
    item_index     integer NOT NULL,
    -- The corpus document this decision is chunked as.
    chunk_doc_id   text NOT NULL,

    -- -- the sitting ------------------------------------------------------
    url            text NOT NULL,
    storage_name   text,
    -- 'OR' (a regular sitting) | 'DEM' (the comité de démolition), off the
    -- file name; sitting_kind is what it means.
    series         text,
    sitting_kind   text NOT NULL,
    -- "2026-25", the Commission's own number for the sitting.
    sitting_number text,
    meeting_date   date,
    -- "C.U. 2026-118" for a list entry (the blanket resolution of its list),
    -- "CD-2025-011" for a hearing item.
    resolution_number text,

    -- -- the request ------------------------------------------------------
    -- "20250428-007": the date the request was filed and a sequence.
    request_number text,
    applicant      text,
    -- The address line as printed, and taken apart: one "N, Street" per
    -- civic token, the first civic number, the street, whether the request
    -- is for a block of doors ("(Bloc)").
    address_line   text,
    addresses      jsonb NOT NULL DEFAULT '[]'::jsonb,
    civic_numbers  jsonb NOT NULL DEFAULT '[]'::jsonb,
    civic          integer,
    street         text,
    is_block       boolean NOT NULL DEFAULT false,
    -- "467, Rue Arago Ouest": the door the row was placed by.
    address_key    text,
    -- Seven-digit lot numbers the item names (a hearing item always does).
    lot_numbers    jsonb NOT NULL DEFAULT '[]'::jsonb,

    -- -- the works --------------------------------------------------------
    -- The permit category and description as printed, one line each.
    works          text,
    -- demolition_main | demolition_accessory | demolition_other |
    -- new_construction | enlargement | subdivision | sign |
    -- special_authorization | exterior_renovation | other
    works_kind     text NOT NULL,
    is_demolition  boolean NOT NULL DEFAULT false,
    -- The dwelling band the category names ("de 1 à 3 logements",
    -- "9 logements et plus") and the project's own count when stated.
    dwellings_min  integer,
    dwellings_max  integer,
    project_dwellings integer,

    -- -- the decision -----------------------------------------------------
    -- approved | approved_conditionally | refused | deferred | withdrawn |
    -- heard | other
    decision       text NOT NULL,
    -- The heading or the operative words it was read from.
    decision_label text,
    -- approved | refused | in_progress, as 032's `outcome`.
    outcome        text,
    -- The Auditions item named this request as heard.
    was_heard      boolean NOT NULL DEFAULT false,

    -- -- the ground -------------------------------------------------------
    lot_number     text,
    -- 'address' | 'address_cardinal'
    match_basis    text,

    -- `rag.chunks.title` of the decision's chunks, and the paragraph they
    -- were cut from (a hearing item's own prose).
    title          text,
    text           text NOT NULL,
    parse_notes    jsonb NOT NULL DEFAULT '[]'::jsonb,
    loaded_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, doc_id, item_index)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS cucq_decisions_request_idx
    ON silver.cucq_decisions (request_number);
CREATE INDEX IF NOT EXISTS cucq_decisions_meeting_idx
    ON silver.cucq_decisions (meeting_date);
CREATE INDEX IF NOT EXISTS cucq_decisions_works_idx
    ON silver.cucq_decisions (works_kind, decision);
CREATE INDEX IF NOT EXISTS cucq_decisions_lot_idx
    ON silver.cucq_decisions (lot_number);
CREATE INDEX IF NOT EXISTS cucq_decisions_chunk_doc_idx
    ON silver.cucq_decisions (chunk_doc_id);
CREATE INDEX IF NOT EXISTS cucq_decisions_addresses_idx
    ON silver.cucq_decisions USING gin (addresses);

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

    EXECUTE format('ALTER TABLE silver.cucq_decisions OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON silver.cucq_decisions TO %I', ro_role);
    END IF;
END
$$;
