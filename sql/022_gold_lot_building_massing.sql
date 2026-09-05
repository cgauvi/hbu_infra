-- gold.lot_building_massing — the highest-and-best-use building of every lot,
-- as a rectangle standing on the ground it would be built on.
--
-- Downstream of gold.lot_highest_best_use (sql/018) for the footprint and
-- silver.lot_buildable_setbacks (sql/015) for the envelope it has to fit
-- inside. The one table in this platform whose output is meant to be *looked
-- at* rather than queried: one polygon per lot, in EPSG:4326, that can be
-- dropped onto a map beside the cadastre to see whether the answer upstream is
-- plausible. Written by hbu_dataplatform's `lot_building_massing` asset — see
-- that repo's `urban_rag.massing`.
--
-- **The rectangle respects the margins by construction.** It is fitted inside
-- the buildable polygon sql/015 computes, which is the parcel with the zone's
-- four setbacks already subtracted — so a rectangle contained in it is a
-- rectangle that honours them, and nothing here re-implements a margin rule.
--
-- **It is a schematic, not a design.** Real buildings are L-shaped, step back
-- above a podium, and put parking under a footprint wider than the tower. A
-- rectangle of the right area in the right place answers the questions this
-- exists for — does it fit, does it look like the block around it, is the
-- solver's answer absurd — and stopping there is what keeps it honest.
--
-- ---------------------------------------------------------------------------
-- What footprint_fit_pct is for
-- ---------------------------------------------------------------------------
--
-- This is the column worth reading and the reason the table exists.
-- `urban_rag.program` caps a footprint at the lesser of two *areas* — *Taux
-- d'implantation au sol* × lot area, and the buildable area left by the
-- margins — and then stops. An area is not a shape: a buildable envelope of
-- 200 m² running 40 m deep and 5 m wide holds no rectangle of 200 m² at all,
-- and a solver working in areas will spend all 200 of them regardless.
--
-- So `footprint_fit_pct` below 100 is this table reporting a shape the answer
-- upstream cannot actually take. Those lots are *shrunk* — the rectangle drawn
-- is the largest of its ratio that does fit, and `placed_footprint_m2` says
-- how big that is — rather than dropped, because dropping them would hide
-- exactly the parcels worth opening a map on. A borough whose median fit is
-- well under 100 is a borough whose footprints are being over-stated, which is
-- a finding about the solver rather than about this table.
--
-- One caveat the column cannot carry on its own: a fit below 100 can also mean
-- the *ratio list* was too short rather than the parcel too thin. The asset
-- tries a few aspect ratios (1:1 through 3:1 by default, each at the parcel's
-- axis and its perpendicular) and stops there, because past 3:1 a "building"
-- is a wall. `aspect_ratio` on every row is what distinguishes the two: a lot
-- reported `shrunk` at the *last* ratio in the list was hitting the list, and
-- one shrunk at an earlier ratio was hitting the parcel. The ratios a run
-- tried are in the asset's own metadata.
--
-- ---------------------------------------------------------------------------
-- The parking is not in this table's geometry, on purpose
-- ---------------------------------------------------------------------------
--
-- A program can park on the ground — `surface_stalls` standing on the yard the
-- footprint leaves — and none of that asphalt is in `geom`. A surface stall is
-- not a building: no floor area, no storey, no height. Folding it into the
-- massing rectangle would inflate the very footprint `footprint_fit_pct` is
-- checking, and a map extruding that rectangle to `height_m` would raise a
-- solid where there is a parking lot.
--
-- So the same asset draws a *second* polygon and publishes it to
-- gold.lot_surface_parking (sql/024), fitted into the **parcel** less this
-- building rather than into the setback envelope — a margin is what a
-- *building* keeps, and a car in a side or rear yard stands exactly where the
-- margin said no building may go. The columns at the end of this table are
-- that answer without its shape, so "does this building's parking fit on this
-- lot" is one row rather than a join.
--
-- ---------------------------------------------------------------------------
-- Every lot keeps a row in the tree; only the drawn ones are here
-- ---------------------------------------------------------------------------
--
-- That split is urban_rag.warehouse's rule rather than this asset's choice: a
-- row with no geometry is skipped on the way into a spatial table, since it
-- cannot be joined, clipped or drawn and would put a hole in every measure
-- taken over the partition. So the lots with `massing_status` of
-- 'no_program', 'no_buildable_geometry' or 'no_fit' are in
-- gold/lot_building_massing/ in the tree and are *not* in this table.
--
-- Nothing is lost by it. A reader who wants the undrawn lots in SQL gets them
-- by anti-joining gold.lot_highest_best_use, which has a row for every lot the
-- envelopes reach and an `hbu_status` saying why it has no program; the run's
-- own metadata reports `num_lots` and `num_drawn` side by side so the gap is
-- never a surprise. `massing_status` is still a column here, and on this table
-- it only ever reads 'fitted' or 'shrunk'.
--
-- No `-- requires:` header: this table names nothing outside its own schema.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO gold, public;

CREATE TABLE IF NOT EXISTS gold.lot_building_massing (
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- Keyed on lot_uid, like gold.lot_highest_best_use whose rows these are
    -- drawn from, and for the same reason: a lot the roll never named still
    -- has an envelope and a building.
    lot_uid      bigint NOT NULL,
    lot_number   text,
    -- The governing (zone, column) the footprint was solved under, carried so
    -- the rectangle can be traced back to the envelope it was fitted into —
    -- silver.lot_buildable_setbacks is keyed on exactly this triple.
    feature_id   text,
    column_index integer,
    -- gold.lot_highest_best_use.hbu_status, restated. On this table it is
    -- always 'solved': a lot without a program has no rectangle and so no row.
    hbu_status   text,
    -- 'fitted' or 'shrunk' here — see the header for the three values that
    -- exist in the tree and never in this table.
    massing_status text NOT NULL,

    -- -- the sanity check ---------------------------------------------------
    --
    -- What the solver costed, and what could actually be drawn of it.
    footprint_m2           double precision,
    placed_footprint_m2    double precision,
    -- footprint_m2 - placed_footprint_m2. Zero on a 'fitted' row.
    footprint_shortfall_m2 double precision,
    -- 100 × placed / solved. The column this table is for; see the header.
    footprint_fit_pct      double precision,

    -- -- the rectangle itself ---------------------------------------------
    --
    -- Which of the tried ratios was drawn, its two sides in metres, and the
    -- bearing of its long axis in degrees. Carried for a reader who wants the
    -- numbers rather than the polygon — and because `aspect_ratio` sitting at
    -- the end of the tried list is what says a shrunk fit was hitting the
    -- list rather than the parcel.
    aspect_ratio double precision,
    width_m      double precision,
    depth_m      double precision,
    rotation_deg double precision,

    -- -- what stands on that footprint -----------------------------------
    --
    -- Carried from gold.lot_highest_best_use so a map can extrude the
    -- rectangle to the height the solver costed without joining back for it.
    floors            integer,
    height_m          double precision,
    residential_floors        integer,
    commercial_floors         integer,
    industrial_floors         integer,
    above_grade_parking_floors integer,
    underground_levels        integer,
    num_dwellings             integer,
    -- What was costed, and what the drawn footprint would actually carry at
    -- the same storey count. The same check as the footprint pair, carried up
    -- to the number *Densité* was tested against.
    gross_floor_area_m2        double precision,
    placed_gross_floor_area_m2 double precision,

    -- -- the envelope it was fitted into, for scale ----------------------
    buildable_area_m2 double precision,
    lot_area_m2       double precision,

    -- EPSG:4326, the rectangle. Unconstrained `Geometry` rather than Polygon,
    -- like every other spatial table here: the fit is done in EPSG:32188 and
    -- projected back, and a narrower type would reject whatever the round trip
    -- happens to produce on a degenerate parcel.
    geom      geometry(Geometry, 4326),
    loaded_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, lot_uid)
) PARTITION BY LIST (neighborhood);

-- The parking, summarised. The polygon itself is in gold.lot_surface_parking
-- (sql/024) and deliberately not here: a surface stall is not a building — no
-- floor area, no storey, no height — so folding it into `geom` would inflate
-- the footprint footprint_fit_pct is checking and would have a map extrude a
-- solid where there is asphalt. What is here is the answer without the shape,
-- so "does this building's parking fit on this lot" needs no join.
--
-- surface_parking_fit_pct is footprint_fit_pct's counterpart and reads the
-- same way: 100 means the yard took the whole reservation once the building
-- was on it, and less means the program is counting on stalls the ground will
-- not give it. parking_status distinguishes a lot that came up short from one
-- that parks underground and from one whose parcel was never loaded — see the
-- asset's PARKING_STATUSES.
ALTER TABLE gold.lot_building_massing
    ADD COLUMN IF NOT EXISTS parking_status text,
    ADD COLUMN IF NOT EXISTS surface_stalls integer,
    ADD COLUMN IF NOT EXISTS placed_surface_stalls double precision,
    ADD COLUMN IF NOT EXISTS surface_parking_area_m2 double precision,
    ADD COLUMN IF NOT EXISTS placed_surface_parking_m2 double precision,
    ADD COLUMN IF NOT EXISTS surface_parking_fit_pct double precision;

-- The map read: "every massing in this bounding box". The reason this table is
-- spatial at all.
CREATE INDEX IF NOT EXISTS lot_building_massing_geom_idx
    ON gold.lot_building_massing USING gist (geom);
-- "Where does the solved footprint not fit its own parcel" — ASC, because the
-- interesting end is the low one. Partial, the way sql/016's cap-rate index
-- is: a lot that fits perfectly is the other question.
CREATE INDEX IF NOT EXISTS lot_building_massing_fit_idx
    ON gold.lot_building_massing (footprint_fit_pct)
    WHERE massing_status = 'shrunk';
-- "The biggest buildings the borough could carry" — the list to draw first.
CREATE INDEX IF NOT EXISTS lot_building_massing_area_idx
    ON gold.lot_building_massing (placed_gross_floor_area_m2 DESC);

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
        'ALTER TABLE gold.lot_building_massing OWNER TO %I', app_role
    );

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON gold.lot_building_massing TO %I', ro_role
        );
    END IF;
END
$$;
