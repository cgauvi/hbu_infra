-- silver.council_planning_items — what Quebec City's conseils de quartier and
-- the decisions they trail to say about zoning, lots and dwellings, as columns.
--
-- One row per *planning item*: an agenda item of a council's procès-verbal
-- (item_index is the agenda number, source_kind 'minutes'), or one document
-- reached from it (item_index 0; source_kind 'fiche', 'gpd',
-- 'consultation_file' or 'council_file'). The same amendment therefore
-- appears several times, once per seat it was described from - the council's
-- consultation, the city's sommaire décisionnel, the arrondissement's
-- resolution, the consultation report - and `bylaw_numbers`, `gpd_numbers`
-- and `subject_zone_codes` are what join those rows back into one decision.
--
-- Every list column is a jsonb array read out of prose by regular expression
-- (the dataplatform's urban_rag.council_items), with the sentence it came from
-- kept: `dwelling_changes` is [{before, after, scope, excerpt}], and
-- `council_opinion_excerpt` is the sentence `council_opinion` was read from.
-- A field the pattern did not reach is null, never guessed, and `parse_notes`
-- says when something was expected and not found.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql. On the borough
-- axis: a council belongs to an arrondissement and its minutes are listed by
-- it, so this stays where the corpus is rather than on the tile cut.

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.council_planning_items (
    scrape_date    date NOT NULL,
    neighborhood   text NOT NULL,
    -- sha256(url)[:16] of the document the item was read from, the same id
    -- bronze/council_minutes and bronze/council_minutes_documents carry.
    doc_id         text NOT NULL,
    item_index     integer NOT NULL,
    -- 'minutes' | 'fiche' | 'gpd' | 'consultation_file' | 'council_file'
    source_kind    text NOT NULL,
    council_id     integer,
    council_name   text,
    -- The assembly the minute records, or the one the trail document was
    -- first reached from.
    meeting_date   date,
    -- The decision system's own number when the document has one: GT2025-233
    -- (a sommaire), CA1-2025-0215 (a resolution extract), AM1-2025-0146.
    document_number text,
    url            text NOT NULL,
    -- The minutes that led here, as a jsonb array of their doc_ids.
    minutes_doc_ids jsonb NOT NULL DEFAULT '[]'::jsonb,

    -- -- what the item is ---------------------------------------------------
    -- zoning_amendment | ppcmoi | minor_variance | demolition |
    -- conditional_use | planning | heritage | housing | other
    item_kind      text NOT NULL,
    title          text,

    -- -- what it names -----------------------------------------------------
    -- The zones the item is *about* (its title, "relativement à la zone",
    -- "zone visée", "dans la zone") against every zone code its text
    -- carries - a sommaire's annexed plan extract labels the neighbours too.
    subject_zone_codes jsonb NOT NULL DEFAULT '[]'::jsonb,
    zone_codes     jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- "R.C.A.1V.Q. 549", "R.V.Q. 978", spelled one way.
    bylaw_numbers  jsonb NOT NULL DEFAULT '[]'::jsonb,
    gpd_numbers    jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- The fiche de modification's "N° de dossier".
    file_number    text,
    subject_addresses jsonb NOT NULL DEFAULT '[]'::jsonb,
    addresses      jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- Seven-digit cadastral lot numbers, spaces removed.
    lot_numbers    jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- "H1", "C2": the usage groups named after "groupe d'usages".
    usage_groups   jsonb NOT NULL DEFAULT '[]'::jsonb,

    -- -- dwellings ---------------------------------------------------------
    dwelling_changes jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- The by-law's cap per building, before and after, from the first
    -- zoning-scoped change; the project's own count from a project-scoped
    -- one or "un total de N logements".
    max_dwellings_before integer,
    max_dwellings_after  integer,
    project_dwellings    integer,
    dwelling_counts  jsonb NOT NULL DEFAULT '[]'::jsonb,

    -- -- envelope ----------------------------------------------------------
    max_height_m   double precision,
    storeys        jsonb NOT NULL DEFAULT '[]'::jsonb,

    -- -- the decision ------------------------------------------------------
    -- adopted | draft_adopted | notice_of_motion | consultation
    decision       text,
    -- The sitting on an extract, the assembly on a report, "Date :" on a
    -- sommaire.
    decision_date  date,
    -- favorable | favorable_with_conditions | unfavorable
    council_opinion text,
    council_opinion_excerpt text,
    -- The consultation report's vote table: {"A": 0, "B": 0, "C": 9,
    -- "Abstention": 0}.
    votes          jsonb NOT NULL DEFAULT '{}'::jsonb,
    parse_notes    jsonb NOT NULL DEFAULT '[]'::jsonb,

    -- The item's first 1,500 characters, and the whole of it.
    excerpt        text,
    text           text NOT NULL,
    loaded_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, doc_id, item_index)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS council_planning_items_kind_idx
    ON silver.council_planning_items (item_kind);
CREATE INDEX IF NOT EXISTS council_planning_items_meeting_idx
    ON silver.council_planning_items (meeting_date);
CREATE INDEX IF NOT EXISTS council_planning_items_zones_idx
    ON silver.council_planning_items USING gin (subject_zone_codes);
CREATE INDEX IF NOT EXISTS council_planning_items_bylaws_idx
    ON silver.council_planning_items USING gin (bylaw_numbers);
CREATE INDEX IF NOT EXISTS council_planning_items_gpd_idx
    ON silver.council_planning_items USING gin (gpd_numbers);

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

    EXECUTE format('ALTER TABLE silver.council_planning_items OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON silver.council_planning_items TO %I', ro_role);
    END IF;
END
$$;
