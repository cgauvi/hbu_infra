-- rag.addresses and silver.lot_addresses — the province's civic addresses, and
-- the parcel each one stands on. One row per address point.
--
-- No `-- requires:` header, for the reason 015 and 025 give: neither table
-- declares a foreign key, so both can be created on a database holding neither
-- rag.lots nor silver.lot_zone_pieces, and the check that those have landed
-- belongs in compute_lot_addresses where it can name every file at once.
--
-- ---------------------------------------------------------------------------
-- The publisher has no lot number
-- ---------------------------------------------------------------------------
--
-- Adresses Québec is the MRNF's official address product — "les données
-- officielles sur les adresses et leur localisation sous forme de points pour
-- tout le Québec" — and it publishes ten fields per address: a formatted
-- address, a civic number and its suffix, a unit count, a stable UUID, a
-- positional note, a version stamp, and the point itself. Nothing cadastral.
-- No NoLot, no matricule, nothing that names a parcel.
--
-- So "what is the address of lot 2 784 705" is not a question that service can
-- be asked, and silver.lot_addresses is the answer to it: the points put on
-- the cadastre by ST_Intersects, which is the only join available.
--
-- The layer is also advertised under a WMS endpoint, and WMS cannot do this
-- either — GetMap returns a picture and GetFeatureInfo answers one pixel at a
-- time, against a layer the same service will not draw above 1:10,000. The
-- REST face of the same ArcGIS MapServer is what hbu_dataplatform reads. See
-- urban_rag.adresses_quebec.
--
-- ---------------------------------------------------------------------------
-- The grain is the piece, because that is what gold is keyed on
-- ---------------------------------------------------------------------------
--
-- Since 025 every gold table is keyed on (lot_uid, feature_id) — the piece of
-- a lot one zone governs, as a site in its own right. An address is therefore
-- placed twice: on its parcel, and within it on the piece it stands in. That
-- is what lets a reader join an address straight onto
-- gold.lot_highest_best_use or gold.lot_investment_opportunities, which is the
-- whole purpose of the table: a map can label a site with something a person
-- recognises instead of a nine-digit lot number, and the corpus can answer
-- "what is at 7430 Rue Lajeunesse" by matching a street and a number.
--
-- lot_number is carried beside lot_uid for the reason every other table here
-- carries it: lot_uid is a bigserial that load_lots mints again on every load,
-- so a join written on it breaks the next time the cadastre is reloaded.
--
-- ---------------------------------------------------------------------------
-- Three bases for a match, and the row says which it used
-- ---------------------------------------------------------------------------
--
--   match_basis = 'within'   the point is inside the parcel. The ordinary case.
--   match_basis = 'snapped'  the point is outside every parcel but within
--                            max_snap_m (2 m) of one, and was given the
--                            nearest. The address points and the cadastre are
--                            two publishers' surveys of the same ground, and
--                            where a point was digitised against a building
--                            face rather than a lot line it lands just outside
--                            the parcel it belongs to. snap_distance_m records
--                            how far it reached.
--   (not written)            the point is on nobody's parcel — it sits in the
--                            right of way, or on ground the cadastre did not
--                            draw. The grain of this table is an address *on a
--                            lot*, so these are counted in the asset's
--                            metadata as num_unmatched and left out rather
--                            than written with a null in the column every
--                            reader joins on.
--
-- piece_basis is the same idea one level down. 'piece' is the point inside one
-- of its lot's zone pieces; 'primary' is a point inside the lot but in none of
-- them, given the lot's largest piece — 025's cutoffs drop slivers, so a
-- parcel's pieces need not cover it entirely; 'none' is a lot no zoning layer
-- governs at all, which takes '-' for feature_id, the same dash 025 writes for
-- a migrated row. A row reading 'none' joins to no gold row, and that is
-- visible rather than mysterious.
--
-- ---------------------------------------------------------------------------
-- A row is an addressable unit, not a front door
-- ---------------------------------------------------------------------------
--
-- Roughly half the points in a dense borough carry a unit prefix: `204-7430
-- Rue Lajeunesse` and `7430 Rue Lajeunesse` are two rows of this layer. So a
-- count of rows on a parcel is a count of addressable units, and counting them
-- as buildings would make one walk-up look like eight.
--
-- Both counts are therefore stated. num_piece_addresses counts the rows on a
-- site; num_piece_civic_addresses counts the distinct civic addresses among
-- them. address_rank orders a site's rows by civic number and then by unit, so
-- is_primary_address marks the lowest-numbered door — the one a map labels the
-- parcel with.
--
-- Computed by hbu_dataplatform (urban_rag.postgis.compute_lot_addresses) once
-- that borough's rag.lots and silver.lot_zone_pieces rows have landed, and
-- written through urban_rag.warehouse — see 003_warehouse.sql.

SET search_path TO silver, public;

-- ---------------------------------------------------------------------------
-- The working set
-- ---------------------------------------------------------------------------
--
-- The fourth member of the `rag` working set, beside lots, buildings and
-- features in 002_spatial.sql. It lives here rather than there because it
-- arrived later and 002 runs on every database this repo has ever created,
-- including ones that will never load an address.
--
-- Not a published dataset: it is the input the join above is computed over,
-- rebuilt from bronze on every run of the partition, and dropping it costs a
-- re-materialization rather than a re-scrape. `attributes` carries the parsed
-- address — hbu_dataplatform splits AdresseFormatee before the load, so the
-- join reads the street name out of the jsonb rather than parsing it in SQL.

CREATE TABLE IF NOT EXISTS rag.addresses (
    address_uid  bigserial PRIMARY KEY,
    -- The publisher's own UUID (`IdAdr`), unique across Québec and stable
    -- across editions of the layer. The natural key a repeated point inside
    -- one load conflicts on, the way rag.lots uses the lot number.
    address_id   text NOT NULL,
    neighborhood text NOT NULL,
    scrape_date  date NOT NULL,
    attributes   jsonb NOT NULL DEFAULT '{}'::jsonb,
    geom         geometry(Point, 4326),
    UNIQUE (address_id, scrape_date)
);

CREATE INDEX IF NOT EXISTS addresses_geom_idx ON rag.addresses USING gist (geom);
CREATE INDEX IF NOT EXISTS addresses_partition_idx
    ON rag.addresses (neighborhood, scrape_date);

-- ---------------------------------------------------------------------------
-- The published table
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS silver.lot_addresses (
    -- The partition key leads, in the order 003_warehouse.sql explains.
    scrape_date  date NOT NULL,
    neighborhood text NOT NULL,
    -- The grain: one address point. Keyed on the publisher's UUID rather than
    -- on (lot_uid, feature_id), because a site legitimately carries many
    -- addresses and keying on the site would let them overwrite each other.
    address_id   text NOT NULL,

    -- -- what it stands on -------------------------------------------------
    --
    -- The columns every gold table is joined on. feature_id is never null: a
    -- lot no zoning layer governs takes '-', and piece_basis says so.
    lot_uid      bigint NOT NULL,
    lot_number   text,
    feature_id   text NOT NULL,
    source_table text,

    -- 'within' or 'snapped', and how far the snap reached. See the header.
    match_basis     text NOT NULL,
    snap_distance_m double precision,
    -- 'piece', 'primary' or 'none'.
    piece_basis     text NOT NULL,

    -- -- the address itself ------------------------------------------------
    --
    -- formatted_address is the publisher's string, kept whole so a row whose
    -- parts did not parse still carries the address a person would read. The
    -- parts beside it come from urban_rag.adresses_quebec.ADDRESS_RE, except
    -- civic_number and civic_suffix, which the layer states in columns of
    -- their own and which therefore win over the parse.
    formatted_address text,
    unit              text,
    civic_number      integer,
    civic_suffix      text,
    -- `7430 Rue Lajeunesse` — the address without its unit, which is the grain
    -- a *door* is counted at. Null where the street did not parse.
    civic_address     text,
    street_name       text,
    municipality      text,
    postal_code       text,
    -- The publisher's own count of units at this address, which is not the
    -- same as the number of rows carrying its civic address.
    num_units         integer,
    characteristic    text,
    -- The layer's freshness stamp (`AQ20260901`), and the only thing it says
    -- about how old the address is.
    source_version    text,
    object_id         bigint,

    -- -- where it ranks on its site ----------------------------------------
    --
    -- Within (lot_uid, feature_id), by civic number and then by unit.
    address_rank              integer NOT NULL,
    is_primary_address        boolean NOT NULL,
    -- Units on this site, and doors on it. Both, because they differ by a
    -- factor of eight on a walk-up — see the header.
    num_piece_addresses       integer NOT NULL,
    num_piece_civic_addresses integer NOT NULL,
    -- The whole parcel's count, for the reader holding one piece.
    num_lot_addresses         integer NOT NULL,

    geom      geometry(Point, 4326),
    loaded_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (scrape_date, neighborhood, address_id)
) PARTITION BY LIST (neighborhood);

CREATE INDEX IF NOT EXISTS lot_addresses_geom_idx
    ON silver.lot_addresses USING gist (geom);
-- The join this table exists for: onto gold, on the piece grain.
CREATE INDEX IF NOT EXISTS lot_addresses_site_idx
    ON silver.lot_addresses (lot_uid, feature_id);
-- The same join for a reader who only has the reload-proof key.
CREATE INDEX IF NOT EXISTS lot_addresses_lot_number_idx
    ON silver.lot_addresses (lot_number);
-- "One address per site" — what a map label and a RAG answer both take.
CREATE INDEX IF NOT EXISTS lot_addresses_primary_idx
    ON silver.lot_addresses (lot_uid, feature_id)
    WHERE is_primary_address;
-- Looking a parcel up *from* an address, which is the direction a person asks
-- in: "what may be built at 7430 Rue Lajeunesse". Lower-cased so the lookup
-- does not depend on how the asker capitalised the street.
CREATE INDEX IF NOT EXISTS lot_addresses_street_idx
    ON silver.lot_addresses (lower(street_name), civic_number);
CREATE INDEX IF NOT EXISTS lot_addresses_postal_idx
    ON silver.lot_addresses (postal_code);

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

    -- ALTER TABLE ... OWNER TO carries the owned sequence with it, so
    -- rag.addresses_address_uid_seq needs no statement of its own.
    FOREACH relation IN ARRAY ARRAY['rag.addresses', 'silver.lot_addresses'] LOOP
        EXECUTE format('ALTER TABLE %s OWNER TO %I', relation, app_role);
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = ro_role) THEN
            EXECUTE format('GRANT SELECT ON %s TO %I', relation, ro_role);
        END IF;
    END LOOP;
END
$$;
