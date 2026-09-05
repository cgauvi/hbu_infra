-- gold.lot_surface_parking — the asphalt of the highest-and-best-use program,
-- drawn on the yard its building leaves.
--
-- The second polygon of hbu_dataplatform's `lot_building_massing` asset, and
-- the sibling of gold.lot_building_massing (sql/022). One asset, one parquet
-- carrying both shapes, two tables published in one transaction — so a reader
-- never sees a building whose parking has not caught up with it.
--
-- ---------------------------------------------------------------------------
-- Why it is not a column of sql/022
-- ---------------------------------------------------------------------------
--
-- Because a surface stall is not a building. It has no floor area, no storey
-- and no height: article 38 1° of by-law 01-283 keeps parking out of the
-- *superficie de plancher* the density index is computed on, and *Taux
-- d'implantation* caps the footprint while the rest of the parcel is a yard.
-- Fold that into the massing rectangle and it inflates the very footprint
-- `footprint_fit_pct` is checking; hand it to a map that extrudes the massing
-- to `height_m` and it raises a solid where there is a parking lot.
--
-- A second *table* rather than a second geometry column on sql/022, because
-- urban_rag.warehouse skips a row with no geometry on the way into a spatial
-- table, and which row to skip is a different answer for each shape. A lot
-- whose building fits and whose parking does not belongs in the massing table
-- and not here. A lot that parks underground belongs in the massing table and
-- not here either. Neither is a hole in the massing, and a single table with
-- two shapes could not say so.
--
-- ---------------------------------------------------------------------------
-- The yard is the parcel, and nothing is reserved for reaching it
-- ---------------------------------------------------------------------------
--
-- The container is the **lot boundary less the drawn building**, not the
-- buildable envelope sql/015 computes. A setback is a margin a *building*
-- keeps; a car standing in a side or rear yard is standing exactly where the
-- margin said no building may go, so fitting the parking inside the margins
-- would put it in the one place it is least likely to be.
--
-- No access route is modelled. A surface stall does not have to front the
-- street and on a Montreal block it usually does not — it is reached from the
-- back lane, or across the front yard of the same parcel — so requiring the
-- asphalt to touch the frontage would refuse the ordinary case. That is a
-- stated assumption rather than a forgotten check: nothing here proves a car
-- can get to the stall it can stand on.
--
-- ---------------------------------------------------------------------------
-- What surface_parking_fit_pct is for
-- ---------------------------------------------------------------------------
--
-- The counterpart of sql/022's footprint_fit_pct, and it reads the same way.
--
-- `urban_rag.program` rations surface stalls two ways. `surface_stall_area ×
-- stalls + footprint <= lot area` is an area against an area, and it is
-- satisfied on a parcel two metres wide where no car stands in any
-- orientation. So the solver is also handed `parkable_area_m2` — the largest
-- parking-shaped rectangle the parcel actually holds, at least 5.5 m deep (a
-- stall's length, article 566) and 2.6 m across — and that is a real
-- constraint on the solve rather than a report about it.
--
-- But `parkable_area_m2` is measured on the *bare* parcel, because at solve
-- time there is no building to subtract: the footprint is the decision it is an
-- input to. This table is where the building exists, so this is where the
-- remainder shows up — a yard that looked adequate against the whole lot and is
-- a ribbon once the plate is on it. A row below 100 is the program counting on
-- stalls the ground will not give it once its own building is standing.
--
-- Those rows are shrunk rather than dropped, for sql/022's reason: the
-- rectangle drawn is the largest the yard does take, and dropping it would hide
-- the parcels worth opening a map on.
--
-- ---------------------------------------------------------------------------
-- Up to three patches, and why more than one
-- ---------------------------------------------------------------------------
--
-- Unlike the building, which is one massing or nothing, `geom` can be a
-- MultiPolygon. Parking honestly comes in pieces: a building across the middle
-- of its parcel leaves a front yard and a rear yard, and stalls in both is the
-- ordinary Montreal answer rather than a compromise. Insisting on a single
-- rectangle would report such a lot at half its real capacity and make the fit
-- column cry wolf on the common case. `num_parking_bays` says how many were
-- used, and parking_width_m/parking_depth_m describe the largest of them.
--
-- ---------------------------------------------------------------------------
-- Only the lots that park on the ground are here
-- ---------------------------------------------------------------------------
--
-- urban_rag.warehouse's rule again: a row with no geometry is not a row of a
-- spatial table. So a lot whose program parks underground, on a deck or in a
-- ground-floor bay has no row here, and neither has one whose yard took
-- nothing — those are in gold/lot_building_massing/ in the tree with a
-- `parking_status` saying which. On this table parking_status only ever reads
-- 'fitted' or 'shrunk'. A reader who wants the rest in SQL joins
-- gold.lot_building_massing, which carries parking_status and the fit summary
-- for every lot it has a building for.
--
-- No `-- requires:` header: this table names nothing outside its own schema.
--
-- Written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO gold, public;

CREATE TABLE IF NOT EXISTS gold.lot_surface_parking (
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- The same key as gold.lot_building_massing, so the building and its
    -- parking join on one column.
    lot_uid      bigint NOT NULL,
    lot_number   text,
    -- The governing (zone, column) the program was solved under, carried for
    -- the same tracing sql/022 carries it for.
    feature_id   text,
    column_index integer,
    hbu_status   text,
    -- The building's status, restated, because the yard is what that building
    -- left: a lot whose massing was 'shrunk' has more yard than its program
    -- was solved against, and that is worth seeing beside this row.
    massing_status text,
    -- 'fitted' or 'shrunk' here — see the header for the five values that
    -- exist in the tree and never in this table.
    parking_status text NOT NULL,

    -- -- the sanity check ---------------------------------------------------
    --
    -- What the solver put on the yard, and what the yard can actually take.
    -- placed_surface_stalls floors the placed area by the per-stall
    -- allowance — half a stall of asphalt parks no car — so it is double
    -- precision rather than integer only because the flooring happens upstream
    -- and NULL has to survive the trip.
    surface_stalls            integer,
    placed_surface_stalls     double precision,
    -- The ground the program reserved, and the ground that was drawn.
    surface_parking_area_m2   double precision,
    placed_surface_parking_m2 double precision,
    -- reserved - placed. Zero on a 'fitted' row.
    surface_parking_shortfall_m2 double precision,
    -- 100 × placed / reserved. The column this table is for; see the header.
    surface_parking_fit_pct   double precision,

    -- -- the rectangle itself ----------------------------------------------
    --
    -- The largest bay's two sides in metres and the bearing of its long axis.
    -- parking_depth_m is the dimension the by-law states and the search holds
    -- at or above 5.5 m; parking_width_m is what the area then asks for.
    parking_width_m    double precision,
    parking_depth_m    double precision,
    parking_rotation_deg double precision,
    -- How many separate patches the asphalt took. 1 is a single lot; more is a
    -- front yard and a rear one, which is ordinary rather than a compromise.
    num_parking_bays   integer,

    -- -- the ground it was found in, for scale ------------------------------
    --
    -- The parcel less the drawn building, the shape-blind cap the solver was
    -- given for the same parcel, and the building that came out of it. Carried
    -- together because the interesting comparison is among them: a yard_area
    -- far above placed_surface_parking_m2 is a parcel with plenty of ground in
    -- the wrong shape.
    yard_area_m2       double precision,
    parkable_area_m2   double precision,
    footprint_m2       double precision,
    placed_footprint_m2 double precision,
    lot_area_m2        double precision,

    -- EPSG:4326, the asphalt. Unconstrained `Geometry` rather than Polygon and
    -- for one more reason than sql/022 has: this one is genuinely a
    -- MultiPolygon wherever the parking took more than one bay.
    geom      geometry(Geometry, 4326),
    loaded_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, lot_uid)
) PARTITION BY LIST (neighborhood);

-- The map read: "every surface parking lot in this bounding box". The reason
-- this table is spatial at all.
CREATE INDEX IF NOT EXISTS lot_surface_parking_geom_idx
    ON gold.lot_surface_parking USING gist (geom);
-- "Where does the program park on ground that cannot hold it" — ASC, because
-- the interesting end is the low one. Partial, the way sql/022's fit index is:
-- a lot whose yard took everything is the other question.
CREATE INDEX IF NOT EXISTS lot_surface_parking_fit_idx
    ON gold.lot_surface_parking (surface_parking_fit_pct)
    WHERE parking_status = 'shrunk';
-- "The most asphalt this borough would lay" — the list to draw first, and the
-- one to argue about.
CREATE INDEX IF NOT EXISTS lot_surface_parking_area_idx
    ON gold.lot_surface_parking (placed_surface_parking_m2 DESC);

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
        'ALTER TABLE gold.lot_surface_parking OWNER TO %I', app_role
    );

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
        EXECUTE format(
            'GRANT SELECT ON gold.lot_surface_parking TO %I', ro_role
        );
    END IF;
END
$$;
