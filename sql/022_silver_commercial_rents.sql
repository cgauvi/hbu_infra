-- silver.commercial_rents — what a square foot of commercial floor earns in
-- one borough, and where the number came from.
--
-- Three rows per (scrape_date, neighborhood): retail, office and industrial.
-- The last missing input to a cap rate. CMHC prices a dwelling and the Altus
-- cost guide prices a building to *put up*; until this table, what a square
-- foot of retail, office or warehouse rents for was two constants in
-- hbu_dataplatform's `urban_rag.program` — $80 and $30 — stated rather than
-- surveyed, and both well above what Montreal actually pays. The measured
-- figures are about $36.59 gross for office and $18.74 gross for industrial.
--
-- Written by hbu_dataplatform's `commercial_rents` asset. See that repo's
-- `urban_rag.marketbeat`, `urban_rag.crspi` and docs/commercial-rents.md.
--
-- ---------------------------------------------------------------------------
-- Two publishers, because neither is enough alone
-- ---------------------------------------------------------------------------
--
-- **Cushman & Wakefield measure levels but publish no retail report.** Their
-- Montreal MarketBeats cover office and industrial, quarterly and free, with a
-- submarket table underneath — and nobody publishes a free Montreal *retail*
-- level at all, which is awkward because retail is most of the commercial
-- floor in a borough of triplexes and corner shops.
--
-- **Statistics Canada cover retail but publish no level.** The Commercial
-- Rents Services Price Index (table 18-10-0260-01) carries Montreal CMA
-- quarterly by building type — office, retail, industrial — but it is an
-- index, `2019=100` per series.
--
-- So retail is a **stated base** carried forward by the retail index, and it
-- is the one rate here with no survey behind it. `source` says `stated_base`
-- on that row and `rent_basis` never says `measured` for it.
--
-- **The index is only ever used to move one series through time.** Retail over
-- Office at one quarter is how retail has moved *relative to* office since
-- 2019 — not the ratio of their rents. Using it to turn an office level into a
-- retail one would silently assume the two were equal in 2019, which they were
-- not, and would produce a confident number wrong by whatever the 2019 gap
-- was. The pipeline's `escalate` takes a single building type for exactly that
-- reason.
--
-- ---------------------------------------------------------------------------
-- The borough gets its own rent
-- ---------------------------------------------------------------------------
--
-- The MarketBeats carry a submarket table, and the pipeline's
-- `MARKETBEAT_SUBMARKETS` crosswalk says which submarket each borough sits in
-- — Villeray-Saint-Michel-Parc-Extension is Midtown North on both the office
-- and the industrial map. That is not decoration: Midtown North office asks
-- about $22.39 gross against $36.59 island-wide, so pricing a Villeray
-- dépanneur at the island average would overstate it by around 60 per cent.
--
-- `is_submarket_rate` is false where the borough has no submarket mapped, or
-- where that sector does not publish one, and the row then carries the
-- whole-market figure. A worse answer, reported as such — the same fallback
-- shape silver.vacancy_rates takes when CMHC suppresses a quartier.
--
-- ---------------------------------------------------------------------------
-- Everything is gross
-- ---------------------------------------------------------------------------
--
-- `rent_psf_cad` is a **gross** annual rent per square foot on all three rows:
-- what a tenant pays, operating costs included. The two publishers do not
-- quote it the same way and the gap is about a quarter of an industrial rent —
-- the office MarketBeat states a full-service (gross) figure in one column,
-- the industrial one states a direct *net* rent with the operating costs
-- beside it in `ADDITIONAL RENT`. The pipeline adds the industrial pair and
-- keeps both halves in `published_net_rent_psf_cad` and
-- `published_additional_rent_psf_cad` so the arithmetic is checkable from the
-- row. Reading the industrial net as though it were gross understates a
-- warehouse by a quarter, which is the kind of error that produces a plausible
-- number rather than a crash.
--
-- No `-- requires:` header: this table names nothing outside its own schema,
-- so it lands on the first `db.py init`.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.commercial_rents (
    -- The partition key leads, in the order 003_warehouse.sql explains.
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- 'retail', 'office' or 'industrial'. The classes hbu_dataplatform's
    -- `rent_class_of` sorts a CUBF use code into: 4000 is retail, 5000 and
    -- 6000 are offices and services, 2000/3000/7000 are industrial. Finer than
    -- the three income classes the lot tables report under, because commerce
    -- splits here and the two halves are dollars apart.
    rent_class   text NOT NULL,

    -- -- what it earns ------------------------------------------------------
    --
    -- Gross, annual, per square foot — see the header. This is the column a
    -- proforma multiplies floor area by.
    rent_psf_cad double precision NOT NULL,
    -- The figure as the publisher stated it, before the index moved it. Equal
    -- to rent_psf_cad when rent_basis is 'measured' or 'stated'.
    published_rent_psf_cad double precision,
    -- The industrial pair, kept so the gross above is checkable from the row.
    -- NULL on the office and retail rows: the office MarketBeat publishes only
    -- a full-service figure, and the retail base is stated gross.
    published_net_rent_psf_cad        double precision,
    published_additional_rent_psf_cad double precision,

    -- -- where it came from -------------------------------------------------
    --
    -- 'cushman_wakefield_marketbeat' or 'stated_base'.
    source        text,
    -- The quarter the level was published or stated for, as the publisher
    -- writes it: '2026-Q2' for a MarketBeat, 'YYYY-MM' for the stated base.
    source_period text,
    source_url    text,
    -- The C&W submarket the figure was taken from, and whether it is the
    -- borough's own or the island-wide fallback. NULL on the retail row: the
    -- stated base has no submarket.
    submarket         text,
    is_submarket_rate boolean NOT NULL DEFAULT false,

    -- -- how it was carried forward -----------------------------------------
    --
    -- The CRSPI series used: 'office', 'retail' or 'industrial'. One series,
    -- both ends — see the header on why it is never crossed with another.
    index_building_type text,
    -- The quarter the rate was carried *to*, as CRSPI writes one (the month
    -- the quarter starts in).
    index_period      text,
    index_base_period text,
    -- One of:
    --   'measured'     the survey quarter is already the index's latest
    --   'escalated'    a surveyed level moved to a later quarter
    --   'unescalated'  the index does not reach one of the two quarters, so
    --                  the level is unmoved — a rate a quarter stale, said so
    --   'stated'       the retail base, which no survey stands behind
    -- A rate with no basis beside it cannot be read against next quarter's.
    rent_basis text,
    -- Free text for what the row could not do: the borough with no submarket,
    -- the class with no free survey. Empty rather than null when there is
    -- nothing to say.
    note       text,

    attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
    loaded_at  timestamptz NOT NULL DEFAULT now(),
    -- One rate per class per borough-day.
    PRIMARY KEY (scrape_date, neighborhood, rent_class)
) PARTITION BY LIST (neighborhood);

-- "What was this priced at, and was it measured or stated" — the read this
-- table exists for, and the one a reader checks before trusting a cap rate.
CREATE INDEX IF NOT EXISTS commercial_rents_class_idx
    ON silver.commercial_rents (rent_class, rent_basis);

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

    EXECUTE format(
        'ALTER TABLE silver.commercial_rents OWNER TO %I', app_role);

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON silver.commercial_rents TO %I', ro_role);
    END IF;
END
$$;
