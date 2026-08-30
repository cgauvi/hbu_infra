-- silver.lot_buildable_setbacks — what is left of a lot once its zone's
-- margins are taken off it. One row per (lot, zone, grid column).
--
-- No `-- requires:` header, for the reason 009 gives and with one addition of
-- its own. The table below declares no foreign key on anything, so it can be
-- created on a database that holds neither silver.lot_frontage nor
-- silver.lot_zoning_envelopes; what needs those two is the *pipeline* that
-- fills it, and that check lives in compute_lot_buildable_setbacks where it
-- can name both files at once. The addition: `_requires` in scripts/db.py
-- matches a single `\S+`, so a header naming two relations would capture
-- "silver.lot_frontage," — comma and all — and skip this file on every init
-- for a relation that can never resolve.
--
-- The grid states four margins — *Avant principale*, *Avant secondaire*,
-- *Latérale*, *Arrière* — and silver.lot_zoning_envelopes has carried all four
-- since sql/012 without anything subtracting them. This is the table that
-- does. It is the second cap on a footprint, and it is independent of the
-- first: *Taux d'implantation au sol* says what share of the parcel may be
-- covered, the margins say *where* on the parcel, and neither implies the
-- other. A deep mid-block lot is normally stopped by coverage and a shallow or
-- corner one by its margins, so the footprint a building may actually take is
-- the lesser of the two — which is `footprint_cap_m2` below.
--
-- Computed by hbu_dataplatform (urban_rag.postgis.compute_lot_buildable_setbacks)
-- once that borough's rag.lots, silver.lot_frontage and
-- silver.lot_zoning_envelopes rows have landed, and written through
-- urban_rag.warehouse — see 003_warehouse.sql.
--
-- ---------------------------------------------------------------------------
-- Why this is not a negative buffer, and not a width × depth rectangle
-- ---------------------------------------------------------------------------
--
-- Two shortcuts suggest themselves and both are wrong.
--
-- `ST_Buffer(lot, -d)` shrinks every edge by the same d. Margins are
-- directional — 6 m at the street, 3 m at the rear, 1.5 m at the sides is an
-- ordinary Montreal grid — so one distance cannot express them, and the
-- number that comes out is not any of the four.
--
-- Estimating a depth from area / frontage and multiplying out
-- (width − 2·side) × (depth − front − rear) is exact only for a rectangle. A
-- borough's cadastre is not rectangles: it has wedges, dog-legs, and parcels
-- whose rear line runs at an angle to the street. The polygon is already in
-- rag.lots and the street edge is already in silver.lot_frontage, so the
-- proxy buys nothing the geometry does not give outright.
--
-- What is done instead is a *directional* subtraction. The lot's own boundary
-- is sorted into four classes, each is buffered by the margin that governs it,
-- and the union of those buffers is differenced out of the parcel:
--
--   front      silver.lot_frontage.geom at frontage_rank = 1 — the boundary
--              that was measured as running along the street, not a line
--              guessed at from the parcel's shape
--   secondary  the same at frontage_rank = 2, which exists only on a corner
--              lot and takes *Avant secondaire* rather than *Avant principale*
--   rear       of what is left, the pieces running within `max_sin` of
--              parallel to the front
--   side       of what is left, everything else
--
-- The rear/side test is the one compute_lot_frontage already uses to decide
-- whether a piece of boundary faces a street, pointed at a different reference
-- line: for a piece of length L whose ends sit d1 and d2 from the front edge,
-- |d1 − d2| / L is the sine of the angle between them — 0 for a piece running
-- parallel to the street, 1 for one running straight at it. A lot's rear line
-- is parallel to its front and its side lines are perpendicular, so one
-- threshold separates them and no trigonometry is needed. `max_sin` travels on
-- every row for the same reason silver.lot_frontage.buffer_m does.
--
-- A lot with no frontage row gets no row here. There is nothing to measure the
-- angles against and no edge to call the front, so the four classes are
-- undefined — and inventing a front from the parcel's longest edge would put
-- the *Avant principale* margin on a party line. The count is reported as
-- asset metadata rather than left to be noticed.
--
-- ---------------------------------------------------------------------------
-- Mode d'implantation, which is why the side margin is not simply subtracted
-- ---------------------------------------------------------------------------
--
-- `side_setback_m` is *not* `side_margin_min_m`. The grid prints a mode
-- alongside the margins — I for isolé, J for jumelé, C for contigu, and VSMPE
-- prints them combined as `I-J` or `I-J-C` — and the mode decides whether the
-- side margin applies at all. A contiguous building is built to the party
-- line: its side setback is zero, and subtracting 1.5 m from both sides of
-- every plex lot in a borough of plex lots would understate the buildable area
-- of most of the stock.
--
-- The most permissive mode the column allows is the one applied, because this
-- table answers what *may* be built and a column printing `I-J-C` permits the
-- contiguous form. So:
--
--   contigu permitted  side_setback_m = 0        — both lines are party lines
--   jumelé permitted   side_setback_m = min / 2  — one line is
--   otherwise          side_setback_m = min      — both margins apply
--
-- Half the margin off both sides rather than the whole margin off one is not
-- an approximation of the area: for any parcel whose side lines are parallel
-- the two remove exactly the same amount, and which side carries the party
-- wall is a fact about the neighbour that no layer here publishes.
-- `side_setback_rule` records which of the three was read, and
-- `side_margin_min_m` carries what the grid actually printed, so a row can
-- always be read back against the rule that produced it.
--
-- ---------------------------------------------------------------------------
-- Null margins
-- ---------------------------------------------------------------------------
--
-- A grid printing `-` states no such norm, and sql/012 stores that as NULL
-- rather than 0 — the distinction urban_rag.zoning_grid exists to preserve.
-- Here the two coincide: a margin that is not stated takes nothing off the
-- lot, so every margin is COALESCEd to 0 for the subtraction. The NULL is
-- still visible in silver.lot_zoning_envelopes for a reader who needs to tell
-- "no rear margin" from "a rear margin of zero".
--
-- *Avant secondaire* falls back to *Avant principale* when the grid states
-- only the one: a corner lot's second street edge is still a street edge, and
-- treating it as unregulated would give a corner parcel more buildable area
-- than the mid-block lot beside it.

SET search_path TO silver, public;

CREATE TABLE IF NOT EXISTS silver.lot_buildable_setbacks (
    -- The partition key leads, in the order 003_warehouse.sql explains.
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- The same key silver.lot_zoning_envelopes declares, and for the same
    -- reason: one candidate envelope per (lot, zone, column), and a lot
    -- straddling two zones legitimately has entries from both.
    lot_uid      bigint NOT NULL,
    feature_id   text NOT NULL,
    column_index integer NOT NULL,
    -- The key that survives a reload, carried for the join gold.lot_profiles
    -- makes: lot_uid is a bigserial load_lots mints again every time.
    lot_number   text,
    source_table text,
    lot_area_m2  double precision,

    -- -- the boundary, as it was sorted ------------------------------------
    --
    -- How many metres of the parcel's edge landed in each class. Diagnostics
    -- rather than inputs — the areas below come from the geometry, not from
    -- these — but they are what says whether the sort was sane: a lot whose
    -- whole boundary came back 'side' has a front edge the angle test did not
    -- agree with, and no area number would show it.
    front_edge_m           double precision,
    secondary_front_edge_m double precision,
    side_edge_m            double precision,
    rear_edge_m            double precision,

    -- -- the margins, as they were applied ---------------------------------
    --
    -- As the grid printed it: 'I-J', 'I-J-C', or a borough spelling the modes
    -- out in words.
    implantation_mode text,
    -- Which reading of that the side setback was computed under: 'contigu',
    -- 'jumele', 'isole', or 'unknown' for a column stating no mode at all —
    -- which is treated as 'isole', the conservative reading. See the header.
    side_setback_rule text,
    -- What the grid printed for *Latérale min*, before the mode rule. NULL
    -- when it printed nothing.
    side_margin_min_m double precision,

    -- The four distances actually differenced out of the parcel, in metres.
    -- Every one is >= 0: an unstated margin is 0 here and NULL upstream.
    front_setback_m           double precision NOT NULL,
    secondary_front_setback_m double precision NOT NULL,
    side_setback_m            double precision NOT NULL,
    rear_setback_m            double precision NOT NULL,

    -- -- the answer ---------------------------------------------------------
    --
    -- What is left of the parcel. 0 is a real answer and not a gap: a lot
    -- narrower than twice its side margin has nowhere to put a building, and
    -- that is the fact the row exists to record.
    buildable_area_m2    double precision NOT NULL,
    buildable_pct_of_lot double precision,

    -- *Taux d'implantation au sol max* × lot_area_m2 — the other cap, carried
    -- beside this one so the two can be compared without a join back. NULL
    -- when the column states no coverage maximum.
    coverage_cap_m2 double precision,
    -- The lesser of the two, which is the footprint a building may actually
    -- take: the margins say where on the lot, the coverage says how much of
    -- it, and a building has to satisfy both. This is the column
    -- urban_rag.program reads.
    footprint_cap_m2 double precision NOT NULL,
    -- Which of the two produced it: 'setbacks' or 'site_coverage'. The useful
    -- half of the answer — a borough where this reads 'setbacks' on most rows
    -- is one whose margins, not its coverage, decide what gets built. Ties go
    -- to 'setbacks', which is the cap that also constrains the *shape*.
    footprint_cap_binding text NOT NULL,

    -- -- carried from the envelope row -------------------------------------
    --
    -- So a reader can pick *the* row for a lot without joining back to
    -- silver.lot_zoning_envelopes: `governs_residential` marks the column
    -- select_residential_column chose for this lot's width, and `pct_of_lot`
    -- ranks two zones covering the same parcel. gold.lot_profiles orders on
    -- exactly this pair.
    pct_of_lot          double precision,
    governs_residential boolean,
    solver_ready        boolean,

    -- -- what it was computed with -----------------------------------------
    --
    -- The house rule silver.lot_frontage.buffer_m and
    -- gold.lot_profiles.max_built_area_m2 follow: a threshold that decides
    -- what a number means travels on every row carrying that number, so a
    -- table can be read back against the settings that produced it.
    --
    -- Sine of the angle within which a piece of boundary counted as parallel
    -- to the front edge, and therefore as rear rather than side.
    max_sin          double precision NOT NULL,
    -- How finely the boundary was chopped before each piece was classified.
    segment_m        double precision NOT NULL,
    -- How far off the boundary a frontage linestring counted as lying on it,
    -- when the street edge was subtracted out.
    edge_tolerance_m double precision NOT NULL,

    -- The buildable envelope itself, not the lot: what a building may stand
    -- on. MultiPolygon because a lot deep enough to be cut in two by its own
    -- side margins legitimately has two, and because ST_Difference returns a
    -- collection often enough that typing it as Polygon would reject rows
    -- that are perfectly correct.
    geom      geometry(MultiPolygon, 4326),
    loaded_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, lot_uid, feature_id, column_index)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS lot_buildable_setbacks_geom_idx
    ON silver.lot_buildable_setbacks USING gist (geom);
CREATE INDEX IF NOT EXISTS lot_buildable_setbacks_lot_number_idx
    ON silver.lot_buildable_setbacks (lot_number);
CREATE INDEX IF NOT EXISTS lot_buildable_setbacks_zone_idx
    ON silver.lot_buildable_setbacks (feature_id);
-- "The most buildable parcels in this borough" is the read this table exists
-- for, and gold.lot_profiles takes exactly this row per lot.
CREATE INDEX IF NOT EXISTS lot_buildable_setbacks_governing_idx
    ON silver.lot_buildable_setbacks (lot_uid)
    WHERE governs_residential;
-- "Where do the margins bind rather than the coverage" — the question the
-- whole table exists to make answerable, and a filter on one column.
CREATE INDEX IF NOT EXISTS lot_buildable_setbacks_binding_idx
    ON silver.lot_buildable_setbacks (footprint_cap_binding);

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
        'ALTER TABLE silver.lot_buildable_setbacks OWNER TO %I', app_role
    );

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON silver.lot_buildable_setbacks TO %I', ro_role
        );
    END IF;
END
$$;
