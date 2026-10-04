-- warehouse.dataset_versions — what was observed, as distinct from what changed.
--
-- `scrape_date` has been carrying two different facts since the pipeline was
-- written: *when the pipeline looked*, and *which version of the data this is*.
-- They were the same thing while every month was materialised whether or not
-- anything had moved. They are not the same thing, and conflating them is what
-- makes twelve identical copies of the assessment roll a year look like twelve
-- snapshots.
--
-- This table separates them:
--
--     scrape_date     when this content FIRST appeared   -> the partition value
--     first_observed  the tick that first saw it
--     last_observed   the most recent tick that saw it unchanged
--
-- So a month in which nothing changed is one UPDATE of `last_observed` - the
-- provenance is still recorded, the payload is simply not duplicated. That is
-- compatible with the bronze contract in the dataplatform's docs/running.md
-- ("bronze records what a publisher returned now"): the observation is kept,
-- and what is dropped is a second identical copy of the answer.
--
-- ---------------------------------------------------------------------------
-- Why the digest is here and not on the data tables
-- ---------------------------------------------------------------------------
--
-- A digest is a fact about a *partition of a dataset*, not about a row. Putting
-- it on the rows would store it a few million times and still not answer "has
-- this changed since last month", which needs the previous value - i.e. a
-- history, which is what this is.
--
-- Keyed on the digest rather than on the date so the same content re-appearing
-- after an intervening change is the row it already was. A publisher that
-- reverts an amendment is a real thing, and it should collapse onto the version
-- it reverted to rather than minting a third.
--
-- ---------------------------------------------------------------------------
-- `partition_key`, not `neighborhood`
-- ---------------------------------------------------------------------------
--
-- Deliberately named for the role rather than for today's value. The axis is
-- moving from the borough to a stable spatial cell, and this table should not
-- need a column rename when it does - the values change from 'VSMPE' to a
-- quadkey, and the question the column answers does not.
--
-- ---------------------------------------------------------------------------
-- The trap worth writing down
-- ---------------------------------------------------------------------------
--
-- When a cell is re-cut - one partition split into its four children - the
-- children are `partition_key` values nothing has ever recorded a digest for,
-- so the next tick reads them as new and re-fetches ground that did not change.
-- Seed the four children's rows from the parent's digest in the same
-- transaction that moves the data. See the dataplatform's `urban_rag.tile_cut`.

SET search_path TO warehouse, public;

CREATE TABLE IF NOT EXISTS warehouse.dataset_versions (
    -- The asset, by the name it is known by in the tree: `neighborhood_lots`,
    -- `lot_zone_pieces`. Matches `urban_rag.warehouse.TABLES`' keys, and the
    -- bronze assets that have no warehouse table use the same names.
    dataset        text NOT NULL,

    -- The partition on whatever axis is in force: a borough key today, a
    -- quadkey cell once the repartition lands.
    partition_key  text NOT NULL,

    -- 32 bytes of SHA-256 over the canonicalised frame. See the dataplatform's
    -- `urban_rag.digest`, which is where every rule about what is and is not
    -- content lives - and which is the module to read before trusting a
    -- comparison made here.
    content_digest bytea NOT NULL,

    -- When this content first appeared. This is the value the data tables
    -- carry in their own `scrape_date`, which is why a snapshot selector that
    -- lists distinct scrape dates now lists versions rather than months.
    scrape_date    date NOT NULL,

    first_observed date NOT NULL,
    last_observed  date NOT NULL,

    -- Reported rather than derived: the digest says *whether* something moved
    -- and this says roughly how much, which is the first thing a human wants
    -- when a dataset that had not changed in a year suddenly does.
    row_count      bigint,

    -- Free-form, for the numbers worth keeping beside a version: which
    -- publisher, which URL, how many rows were dropped on the way in.
    attributes     jsonb NOT NULL DEFAULT '{}'::jsonb,

    loaded_at      timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (dataset, partition_key, content_digest),

    CONSTRAINT dataset_versions_digest_is_sha256
        CHECK (octet_length(content_digest) = 32),
    CONSTRAINT dataset_versions_observation_window
        CHECK (last_observed >= first_observed)
);

-- The read the decision is made with: "what is the current version of this
-- dataset in this partition". `last_observed DESC` leads because that is the
-- ordering the answer is the first row of.
CREATE INDEX IF NOT EXISTS dataset_versions_current_idx
    ON warehouse.dataset_versions (dataset, partition_key, last_observed DESC);

-- The read a retention pass makes: which versions of anything are old enough
-- to drop, across every dataset at once.
CREATE INDEX IF NOT EXISTS dataset_versions_scrape_date_idx
    ON warehouse.dataset_versions (scrape_date);

COMMENT ON TABLE warehouse.dataset_versions IS
    'One row per (dataset, partition, content version). A tick that finds the '
    'digest unchanged bumps last_observed and writes nothing else.';


-- ---------------------------------------------------------------------------
-- The current version of each dataset, which is what a reader almost always
-- wants and would otherwise write a window function for.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW warehouse.current_dataset_versions AS
SELECT DISTINCT ON (dataset, partition_key)
       dataset,
       partition_key,
       content_digest,
       scrape_date,
       first_observed,
       last_observed,
       row_count,
       -- How long this version has stood. The column that says out loud what
       -- the whole feature is for: a big number here is a dataset the pipeline
       -- has correctly stopped rewriting.
       (last_observed - first_observed) AS days_unchanged,
       attributes
  FROM warehouse.dataset_versions
 ORDER BY dataset, partition_key, last_observed DESC, scrape_date DESC;

COMMENT ON VIEW warehouse.current_dataset_versions IS
    'The newest observed version of every dataset partition, with how long it '
    'has stood unchanged.';
