-- The CMHC Rental Market Survey, cut to a borough — four silver tables.
--
-- CMHC surveys the Montreal *census metropolitan area* and divides it into its
-- own neighborhoods, which do not line up with the boroughs this platform is
-- partitioned on: `VSMPE` is three CMHC quartiers, `Outremont` is one, and
-- `PR` is the borough plus a neighbouring municipality CMHC will not split
-- out. The crosswalk is `urban_rag.partitions.CMHC_QUARTIERS`, and applying it
-- is exactly what the silver assets `vacancy_rates` and `average_rents` do.
--
-- Two tables per asset, because a borough figure is only readable next to what
-- went into it:
--
--   silver.vacancy_rates            the borough average, one row per
--                                   dwelling type x bedroom class
--   silver.quartier_vacancy_rates   the CMHC rows it was averaged over
--   silver.average_rents            the borough average, one row per
--                                   bedroom class
--   silver.quartier_average_rents   the CMHC rows it was averaged over
--
-- The average is *unweighted*: this publication prints rates and nothing to
-- weight them by — the universe counts are in a different CMHC table — so a
-- borough figure is the mean of its quartiers, each counting once. That is why
-- `num_quartiers` (how many published a rate) and `num_quartiers_mapped` (how
-- many the crosswalk names) are both on every row: with most cells suppressed,
-- the denominator the mean was actually taken over is rarely the full set, and
-- a rate without it is not a number anyone can check.
--
-- A suppressed cell is a row, not an absence. Every dwelling type x bedroom
-- class is emitted whether or not CMHC published it, so the grid is the same
-- shape for every borough and `status` says which of the three it is
-- (published / suppressed / no units).
--
-- New tables: before this file, neither asset reached Postgres at all — they
-- were parquet-only, and `gold.lot_profiles` picked their figures up from the
-- tree as jsonb. That still happens, and is still the right shape for a
-- per-lot read; these tables are for the question asked the other way round,
-- "what did this borough's market look like", which had nowhere to be asked.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql for the
-- partitioning and the upsert every primary key here exists to serve.

SET search_path TO silver, public;

-- ---------------------------------------------------------------------------
-- Vacancy
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.vacancy_rates (
    scrape_date          date NOT NULL,
    neighborhood         text NOT NULL,
    -- 'all', 'apartment', 'row' ... and 'all', 'bachelor', '1_bedroom' ...
    -- Together they are the grid this table publishes, so together they are
    -- the key: one cell per borough-day.
    dwelling_type        text NOT NULL,
    bedroom_type         text NOT NULL,
    -- NULL rather than 0 when nothing was published: a suppressed cell was not
    -- measured at zero per cent, it was not released.
    vacancy_rate_pct     double precision,
    min_vacancy_rate_pct double precision,
    max_vacancy_rate_pct double precision,
    -- How many quartiers actually published a rate for this cell — the
    -- denominator the mean above was taken over.
    num_quartiers        integer NOT NULL DEFAULT 0,
    -- ... and which ones, by name, so a reader can see whether the borough
    -- figure rests on all three or on one.
    averaged_quartiers   text,
    -- How many the crosswalk names, published or not. num_quartiers below this
    -- is the normal state, not a fault.
    num_quartiers_mapped integer,
    -- The survey this came from, carried down from the bronze snapshot rather
    -- than from whatever the resource is configured for today.
    survey_year          integer,
    survey_period        text,
    -- When the crosswalk was applied — the silver asset's own clock, distinct
    -- from the bronze scrape it read.
    conformed_at         timestamptz,
    loaded_at            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, dwelling_type, bedroom_type)
) PARTITION BY LIST (neighborhood);

CREATE TABLE IF NOT EXISTS silver.quartier_vacancy_rates (
    scrape_date      date NOT NULL,
    neighborhood     text NOT NULL,
    -- CMHC's own neighborhood, relabelled to the crosswalk's spelling so two
    -- survey years stack without the punctuation drifting.
    quartier         text NOT NULL,
    dwelling_type    text NOT NULL,
    bedroom_type     text NOT NULL,
    vacancy_rate_pct double precision,
    -- CMHC's own letter grade on the estimate: a, b, c, d.
    reliability      text,
    -- published / suppressed / no_units. The reason a rate is NULL.
    status           text,
    province         text,
    centre           text,
    zone             text,
    survey_year      integer,
    survey_period    text,
    scraped_at       timestamptz,
    conformed_at     timestamptz,
    loaded_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, quartier, dwelling_type, bedroom_type)
) PARTITION BY LIST (neighborhood);

-- ---------------------------------------------------------------------------
-- Rents
--
-- Same shape one measure over, minus the dwelling-type axis: the average-rent
-- table CMHC publishes in reading mode is by bedroom class only.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.average_rents (
    scrape_date          date NOT NULL,
    neighborhood         text NOT NULL,
    bedroom_type         text NOT NULL,
    average_rent_cad     double precision,
    min_average_rent_cad double precision,
    max_average_rent_cad double precision,
    num_quartiers        integer NOT NULL DEFAULT 0,
    averaged_quartiers   text,
    num_quartiers_mapped integer,
    survey_year          integer,
    survey_period        text,
    conformed_at         timestamptz,
    loaded_at            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, bedroom_type)
) PARTITION BY LIST (neighborhood);

CREATE TABLE IF NOT EXISTS silver.quartier_average_rents (
    scrape_date      date NOT NULL,
    neighborhood     text NOT NULL,
    quartier         text NOT NULL,
    bedroom_type     text NOT NULL,
    average_rent_cad double precision,
    reliability      text,
    status           text,
    centre           text,
    survey_year      integer,
    survey_period    text,
    scraped_at       timestamptz,
    conformed_at     timestamptz,
    loaded_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, quartier, bedroom_type)
) PARTITION BY LIST (neighborhood);

-- The read these four exist for is "this borough's market, this survey year",
-- and the partition already narrows to the borough-month; what is left to
-- index is the year.
CREATE INDEX IF NOT EXISTS vacancy_rates_year_idx
    ON silver.vacancy_rates (survey_year);
CREATE INDEX IF NOT EXISTS quartier_vacancy_rates_year_idx
    ON silver.quartier_vacancy_rates (survey_year);
CREATE INDEX IF NOT EXISTS average_rents_year_idx
    ON silver.average_rents (survey_year);
CREATE INDEX IF NOT EXISTS quartier_average_rents_year_idx
    ON silver.quartier_average_rents (survey_year);

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
        'silver.vacancy_rates', 'silver.quartier_vacancy_rates',
        'silver.average_rents', 'silver.quartier_average_rents'
    ] LOOP
        EXECUTE format('ALTER TABLE %s OWNER TO %I', relation, app_role);
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
            EXECUTE format('GRANT SELECT ON %s TO %I', relation, ro_role);
        END IF;
    END LOOP;
END
$$;
