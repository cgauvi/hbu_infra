-- gold.lot_profiles — every lot in a borough, with what stands on it, what it
-- faces, and what governs it. One row per cadastral parcel.
--
-- The gold table of the lot lineage, and the one a highest-and-best-use
-- question is read out of. It replaces an earlier `rag.vacant_lots`, which
-- selected only the parcels carrying nothing: that table answered "where is
-- the empty land" and could answer nothing else, because a lot dropped by its
-- WHERE clause is a lot the reader can no longer see. Keeping every lot and
-- carrying `has_building` instead costs one boolean and makes the vacant-land
-- question a filter rather than a table —
--
--     SELECT * FROM gold.lot_profiles WHERE NOT has_building
--
-- — while leaving "the widest built lots on Rue Jarry" answerable from the
-- same rows. That is why this file exists and 009_vacant_lots.sql never did.
--
-- Computed by hbu_dataplatform (urban_rag.postgis.compute_lot_profiles) once
-- that borough's silver.building_lot_intersections, silver.lot_frontage and
-- silver.lot_features rows have landed — see its README. Three joins collapse
-- into this one table, each from one row per (lot × something) down to one row
-- per lot:
--
--   silver.building_lot_intersections → num_buildings, built_area_m2, category
--   silver.lot_frontage               → primary_* and secondary_*, num_frontages
--   rag.lot_documents                 → doc_* and documents
--
-- A fourth arrives from a table too, and is the one exception to the shape:
--
--   silver.lot_assessed_values        → total_assessed_value and its counts
--
-- That one is already one row per lot, so it is a plain LEFT JOIN rather than
-- a grouped CTE. It is what makes this table answer the whole of the
-- highest-and-best-use question rather than half of it — what the ground is
-- worth as it stands, against what the cost columns below say it would take to
-- build on it.
--
-- Four more arrive as jsonb, handed in by the asset from the geoparquet tree
-- rather than read out of a table, because none of them is loaded into
-- Postgres at the grain this one needs:
--
--   silver/lot_zoning_envelopes        → zoning_envelopes, num_zoning_envelopes
--   silver/vacancy_rates               → vacancy_rates, overall_vacancy_rate_pct
--   silver/average_rents               → average_rents, overall_average_rent_cad
--   bronze/montreal_*_costs            → construction_costs, and the six rate
--                                        columns flattened out of it
--
-- The last three are figures repeated on every lot of a partition — the CMHC
-- pair is the borough's, the cost guide's is the whole city's. That is
-- deliberate: it is what let silver/lots_with_vacancy_rates go, an asset whose
-- whole job was pivoting the CMHC grid onto the cadastre one layer earlier —
-- where it rode through rag.lots.attributes and every spatial join downstream
-- without anything reading it.
--
-- No `-- requires:` header, unlike 006 and 003. The table below names only
-- rag.lots, so it can be created on a database that has never held a chunk;
-- what needs rag.lot_documents is the pipeline that fills it, and that check
-- lives in compute_lot_profiles where it can say which file to apply.
--
-- ---------------------------------------------------------------------------
-- Moved from rag.lot_profiles
-- ---------------------------------------------------------------------------
--
-- `lot_profiles` is a gold asset, so its table is in `gold` and partitioned by
-- neighborhood and scrape date like every other one — see 003_warehouse.sql.
-- The surrogate `lot_profile_uid` is gone with the move (a partitioned table's
-- primary key must contain the partition keys, and no reader ever cited it),
-- and the grain the old UNIQUE (lot_uid) declared is now stated in the column
-- that survives a reload:
--
--     PRIMARY KEY (scrape_date, neighborhood, lot_number)
--
-- which is what the pipeline's upsert conflicts on. `lot_uid` stays as a plain
-- column: it is the bigserial rag.lots mints, useful for joining back to the
-- cadastre within a partition and worthless across one.
--
-- The old table is left in place; drop it once nothing reads it:
--
--     DROP TABLE IF EXISTS rag.lot_profiles;
--
-- Owned by the pipeline's role, handed over below.

SET search_path TO gold, public;

CREATE TABLE IF NOT EXISTS gold.lot_profiles (
    -- The partition key leads, in the order 003_warehouse.sql explains.
    scrape_date      date NOT NULL,
    neighborhood     text NOT NULL,
    -- Infolot's own lot number, and the key of this table: rag.lots.lot_uid is
    -- a bigserial a reload mints again, and the number is what survives one.
    lot_number       text NOT NULL,
    lot_uid          bigint REFERENCES rag.lots (lot_uid) ON DELETE CASCADE,
    lot_area_m2      double precision,
    -- -- what stands on it --------------------------------------------------
    --
    -- `has_building` is the plain reading of the question — does any footprint
    -- at all intersect this parcel — and is deliberately NOT the negation of
    -- "vacant". A lot with a 12 m2 shed has has_building = true and is still
    -- empty in substance; `category` is where that distinction lives, because
    -- it depends on a threshold and a boolean cannot carry one.
    has_building     boolean NOT NULL,
    num_buildings    integer NOT NULL,
    -- Footprint area *clipped to this lot*, not the area of the buildings that
    -- overlap it: a warehouse straddling the boundary counts only for the
    -- slice actually inside, which is what "how much of this lot is built on"
    -- means.
    built_area_m2    double precision NOT NULL,
    built_pct_of_lot double precision,
    -- The largest whole building touching the lot, unclipped. What separates a
    -- shed standing on the parcel from the corner of the neighbour's triplex
    -- crossing the cadastral line.
    largest_building_area_m2 double precision NOT NULL,
    -- One of: 'built', 'no_building', 'shed_only', 'building_sliver'. The four
    -- cases fall out of one threshold; see compute_lot_profiles.
    category         text NOT NULL,
    -- The cutoff `category` was computed with, in m2 of footprint. The word
    -- 'shed_only' means nothing without it, so it travels on every row rather
    -- than only in the run's config — the same rule silver.lot_frontage.buffer_m
    -- follows.
    max_built_area_m2 double precision NOT NULL,

    -- -- what it faces -----------------------------------------------------
    --
    -- silver.lot_frontage holds one row per (lot, street side); these are its top
    -- two, pivoted. Ranks beyond the second are dropped from the columns but
    -- still counted in num_frontages and summed into total_frontage_m, so a
    -- lot facing three streets stays visible as one without every other row
    -- carrying a third pair of empty columns.
    num_frontages    integer NOT NULL,
    total_frontage_m double precision NOT NULL,
    -- NULL, not 0, when the lot faces no street at all: an interior parcel and
    -- a parcel whose street snapshot stops short of it are both unmeasured,
    -- and 0 would claim they were measured at zero.
    primary_frontage_m    double precision,
    primary_street_name   text,
    primary_cote_rue_id   text,
    -- NULL on every interior lot and on every mid-block lot — only a corner
    -- parcel has a second street edge.
    secondary_frontage_m  double precision,
    secondary_street_name text,
    secondary_cote_rue_id text,
    -- The buffer silver.lot_frontage was computed with, carried for the same
    -- reason max_built_area_m2 is. NULL when the lot has no frontage row to
    -- take it from.
    frontage_buffer_m double precision,

    -- -- what governs it ---------------------------------------------------
    --
    -- The highest-coverage document over the lot, flattened out of `documents`
    -- so the common read — "the PDF for this parcel" — is a column rather than
    -- a jsonb path.
    num_documents    integer NOT NULL,
    doc_id           text,
    doc_url          text,
    doc_title        text,
    doc_source_table text,
    doc_pct_of_lot   double precision,
    -- Every document that applies, most-of-the-lot first: an array of
    -- {source_table, feature_id, doc_id, url, title, pct_of_lot}. jsonb rather
    -- than a child table because nothing joins to it — it is read whole, with
    -- the row, and a lot legitimately has a dozen entries across two dozen
    -- published layers.
    documents        jsonb NOT NULL DEFAULT '[]'::jsonb,

    -- -- what may be built on it ------------------------------------------
    --
    -- silver/lot_zoning_envelopes holds one row per (lot, grid column) — the
    -- grain urban_rag.program solves at — and this is that lot's rows, the
    -- zone covering most of it first. jsonb rather than a child table for the
    -- same reason `documents` is: nothing joins to it, it is read whole with
    -- the row, and a lot straddling two zones legitimately has half a dozen
    -- entries. Each object carries the zone it came from, the usages its
    -- column heads, and every norm that column states, so a reader holding one
    -- profile row has what solve_program needs without opening the silver
    -- parquet.
    --
    -- `governs_residential` inside an entry marks the column
    -- select_residential_column picks for this lot's width. There is at most
    -- one per (lot, zone) and often none — a lot whose zone published no
    -- readable grid has no entry at all — so it is not flattened into a column
    -- of its own the way doc_url is.
    num_zoning_envelopes integer NOT NULL DEFAULT 0,
    zoning_envelopes jsonb NOT NULL DEFAULT '[]'::jsonb,

    -- -- what the ground on it is assessed at ------------------------------
    --
    -- silver.lot_assessed_values, carried onto the profile. Alone among this
    -- table's joined inputs it already holds one row per lot — its own primary
    -- key is (scrape_date, neighborhood, lot_number) — so it arrives by a
    -- plain LEFT JOIN on lot_number rather than a grouped CTE, and cannot fan
    -- the row out. Joined on lot_number and not lot_uid for the reason the
    -- envelopes are: lot_uid is a bigserial load_lots mints again on every
    -- reload, and the assessment table does not carry one at all.
    --
    -- Quebec's rôle d'évaluation foncière values the property and draws no
    -- lot; Infolot draws the lot and says nothing about its worth. That asset
    -- is the join nobody publishes, and this is the column a
    -- highest-and-best-use question actually asks for: what the ground is
    -- worth standing as it is, next to what it would cost to build on it.
    --
    -- Assessment units standing on the lot. 0 is a real answer — a lane, a
    -- park, a city parcel — and it is why the total below is nullable. Not
    -- decoration either: a divided-co-ownership building is one unit per
    -- apartment, all of them on the one PC-* common-parts lot, and the first
    -- VSMPE snapshot has 402 units and $258M on a single parcel. The total
    -- only means what a reader thinks it means with the count beside it.
    num_assessment_units integer NOT NULL DEFAULT 0,
    -- Of those, the ones standing on another lot too — whose whole value is
    -- counted here *and* there. Exactly where the two totals below diverge; 0
    -- for most lots, and the two are then equal.
    num_shared_units integer NOT NULL DEFAULT 0,
    -- Of those, the ones placed by where their assessment point falls because
    -- the roll's own lot-number crosswalk could not place them. On a
    -- condominium's PC-* lot this is all of them — the roll names the private
    -- lots, Infolot draws the common parts — and on an ordinary lot it is 0.
    -- Carried so a total can be read back against the route that produced it,
    -- the same rule max_built_area_m2 and frontage_buffer_m follow.
    num_units_by_point integer NOT NULL DEFAULT 0,
    -- Sum of rl0404a (VALEUR IMMEUBLE: land plus buildings, on the roll in
    -- force) over those units, each counted whole. **NULL, not 0, when there
    -- are none** — the same rule primary_frontage_m follows. A sum over
    -- nothing is not a value of zero, and a reader averaging $0 across the
    -- borough's lanes would be answering a question it did not ask.
    --
    -- Right for "what is the property on this lot worth", wrong to SUM()
    -- across a borough: a unit spanning several lots is counted whole on each
    -- of them, by $5.1B of $29.4B on the first VSMPE snapshot. Use the
    -- apportioned column for that one.
    --
    -- numeric rather than double precision, as in 013: these are dollars
    -- summed over hundreds of rows and a borough's roll runs to $27 billion.
    total_assessed_value numeric,
    -- The same, with each unit's value divided across the lots it covers, so
    -- this is the column that adds up across lots and the one above is not.
    total_assessed_value_apportioned numeric,
    -- Fiscal year of the roll the values came from, not the scrape date. The
    -- roll is triennial and this table's date axis is the cadastre's: two
    -- scrape dates three months apart carry the same roll, two a year apart
    -- may not, and nothing else in the row would say so.
    roll_year integer,

    -- -- what the rental market around it looks like -----------------------
    --
    -- CMHC surveys neighborhoods, not parcels, so these two are the
    -- *borough's* figures and are identical on every lot of a (neighborhood,
    -- scrape_date). They are here rather than in a table of their own because
    -- the question this one is read for — what is this parcel worth building —
    -- is asked one lot at a time and answered against the market the lot sits
    -- in. Denormalising a dozen survey cells onto every row is the same trade
    -- `documents` makes, and the same one silver/lots_with_vacancy_rates used
    -- to make by pivoting the grid onto the cadastre itself; doing it here
    -- instead is what let that asset go.
    --
    -- Objects rather than arrays: {survey_year, survey_period,
    -- num_quartiers_mapped, overall_*, cells: [...]}. The provenance is what
    -- makes the cells readable — a borough figure is the unweighted mean of
    -- its quartiers, most of them suppressed, so `num_quartiers` on each cell
    -- is the denominator that mean was actually taken over.
    --
    -- '{}' and a published-but-empty grid are different answers: an empty
    -- object is a partition whose CMHC silver asset has not run, while an
    -- object whose cells all read null is a borough CMHC suppresses entirely.
    -- Both happen, and only the first is a pipeline problem.
    vacancy_rates    jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- The all-dwellings x all-bedrooms cell, flattened out of the object above
    -- so the common read is a column — the same rule doc_url follows. NULL
    -- when CMHC suppressed it, which for a small borough is most years.
    overall_vacancy_rate_pct double precision,
    average_rents    jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- The all-bedrooms cell, same rule.
    overall_average_rent_cad double precision,

    -- -- what it costs to build there --------------------------------------
    --
    -- The Altus Group Canadian Cost Guide's Montreal column, as
    -- bronze/montreal_residential_costs and bronze/montreal_nonresidential_costs
    -- publish it. City-wide figures, so — like the CMHC pair above, only more
    -- so — they are identical on every row of the partition and there is
    -- nothing per-lot to join on: the guide prices nine Canadian markets and
    -- knows nothing about boroughs, let alone parcels. They are here for the
    -- same reason the rents are: the question this table is read for is what a
    -- parcel is worth building, and that is a rent on one side and a cost per
    -- square foot on the other, asked one lot at a time.
    --
    -- {source_url, source_last_modified, cost_scrape_date, city, city_label,
    --  condo_band, parking: [...], residential: [...]} — each entry carrying
    --  the publisher's own id, label, rate_low, rate_high and unit_flag.
    -- '{}' is a partition whose bronze snapshot has not been read, which is a
    -- different answer from a guide that priced nothing.
    construction_costs jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- Dollars per *stall*, not per square foot — the guide flags these rows
    -- `perStall` and it is the reason unit_flag travels in the jsonb at all.
    -- Underground (`parkade_ug`) is the dearer per stall and the larger per
    -- stall; the integrated ground-level garage (`parkade_ag`) is cheaper but
    -- burns floor area the envelope would rather spend on dwellings, which is
    -- what makes the choice between them a choice. urban_rag.program solves it,
    -- against the midpoints of exactly these two pairs.
    underground_stall_cost_low_cad  double precision,
    underground_stall_cost_high_cad double precision,
    above_grade_stall_cost_low_cad  double precision,
    above_grade_stall_cost_high_cad double precision,

    -- Dollars per square foot to build the condominium / apartment band named
    -- by `construction_costs ->> 'condo_band'`, flattened out of the object
    -- above so the common read is a column — the same rule doc_url and
    -- overall_average_rent_cad follow. Which band that is, is a judgement about
    -- the built form rather than a property of the data (wood frame up to six
    -- storeys is what a borough of triplexes builds; a downtown lot is not),
    -- so it is configured per run and named on every row — the same rule
    -- max_built_area_m2 follows. The other four bands stay in the jsonb.
    condo_cost_low_cad_sqft  double precision,
    condo_cost_high_cad_sqft double precision,

    geom             geometry(MultiPolygon, 4326),
    loaded_at        timestamptz NOT NULL DEFAULT now(),
    -- One profile per lot per borough-day. rag.lots already scopes a lot
    -- number to a single (borough, scrape_date), so this is the grain the
    -- table declares and the conflict target the upsert names.
    PRIMARY KEY (scrape_date, neighborhood, lot_number)
) PARTITION BY LIST (neighborhood);

-- ---------------------------------------------------------------------------
-- Widening an existing table
--
-- CREATE TABLE IF NOT EXISTS above is a no-op on a database that already holds
-- gold.lot_profiles, so a column added after this file first ran has to arrive
-- as an ALTER here, the way the seven that arrived after rag.lot_profiles's
-- first release did:
--
--     ALTER TABLE gold.lot_profiles
--         ADD COLUMN IF NOT EXISTS <name> <type> ...;
--
-- ADD COLUMN IF NOT EXISTS makes each one idempotent, and a default means
-- existing rows read as "nothing was carried" rather than NULL — which is the
-- truth about them until their partition is recomputed. It goes here, ahead of
-- the indexes, in case one of them is on a column it adds.
-- ---------------------------------------------------------------------------

-- silver.lot_assessed_values, joined on lot_number. The counts default to 0
-- and the two totals stay NULL, which is the same distinction the CREATE TABLE
-- above draws and the truth about a row until its partition is recomputed: no
-- unit has been placed on it *yet*, as against a lot carrying none.
ALTER TABLE gold.lot_profiles
    ADD COLUMN IF NOT EXISTS num_assessment_units integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS num_shared_units integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS num_units_by_point integer NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS total_assessed_value numeric,
    ADD COLUMN IF NOT EXISTS total_assessed_value_apportioned numeric,
    ADD COLUMN IF NOT EXISTS roll_year integer;

-- Created on the parent, so every partition warehouse.ensure_partition adds
-- gets them without anyone remembering to. The (neighborhood, scrape_date)
-- index the old table needed is gone: that filter is now partition pruning.
CREATE INDEX IF NOT EXISTS lot_profiles_geom_idx
    ON gold.lot_profiles USING gist (geom);
CREATE INDEX IF NOT EXISTS lot_profiles_number_idx
    ON gold.lot_profiles (lot_number);
-- "The empty parcels in this borough, widest first" is the read that used to
-- be a table of its own, so it gets the index that table would have had.
CREATE INDEX IF NOT EXISTS lot_profiles_vacant_idx
    ON gold.lot_profiles (primary_frontage_m DESC)
    WHERE NOT has_building;
-- "The widest lots in this borough" over the whole inventory, built or not.
CREATE INDEX IF NOT EXISTS lot_profiles_frontage_idx
    ON gold.lot_profiles (primary_frontage_m DESC);
CREATE INDEX IF NOT EXISTS lot_profiles_documents_idx
    ON gold.lot_profiles USING gin (documents);
-- "Which lots does this zone govern" and "which lots can be solved for
-- housing" are both containment queries over the array, the same shape the
-- documents index serves.
CREATE INDEX IF NOT EXISTS lot_profiles_envelopes_idx
    ON gold.lot_profiles USING gin (zoning_envelopes);
-- "The most valuable ground in this borough", which is the read the assessment
-- lineage exists for. Partial for the reason 013's twin is: a NULL total is
-- the *other* question — the lots carrying no assessed property at all — and a
-- full index would carry every lane in the borough to answer neither.
CREATE INDEX IF NOT EXISTS lot_profiles_assessed_idx
    ON gold.lot_profiles (total_assessed_value DESC)
    WHERE total_assessed_value IS NOT NULL;

DO $$
DECLARE
    app_role text := 'urban_rag';
    ro_role  text := 'urban_rag_ro';
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = app_role) THEN
        RAISE NOTICE
            'role % does not exist — apply 000_roles.sql, then re-run this '
            'file to hand over ownership', app_role;
        RETURN;
    END IF;

    EXECUTE format('ALTER TABLE gold.lot_profiles OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format('GRANT SELECT ON gold.lot_profiles TO %I', ro_role);
    END IF;
END
$$;
