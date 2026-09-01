# hbu_infra

Terraform for **hbu**: a RAG database — Amazon RDS for PostgreSQL with
**PostGIS** and **pgvector** — the CLI that talks to it, and the Streamlit
front end that reads it, on Fargate behind a load balancer.

The corpus and the geometry live in one database on purpose. `hbu_dataplatform`
scrapes Montreal's zoning layers and embeds the PDFs they link to; a
highest-and-best-use question needs both halves at once — *what do the rules
say* is a vector search, *which rules apply here* is a spatial one, and neither
answer is worth much alone.

The front end lives in the same stack for a related reason. The registry it is
pulled from, the cluster it runs on, the secrets it reads and the security group
that lets it reach 5432 are all things this stack's networking and IAM already
describe — splitting them out would mean publishing half of them as outputs and
consuming them back.

There is no CI yet. Every apply is manual, and the state backend is the only
thing bootstrapped ahead of it.

---

## Layout

Three stacks, each with its own state, following the same split as
[`ebird-llm/infra`](../ebird-llm/infra):

| Stack | State key | Owns |
|---|---|---|
| [`bootstrap/`](bootstrap/) | *local* | The S3 state bucket and DynamoDB lock table. Applied once. |
| [`shared/`](shared/) | `hbu/shared/terraform.tfstate` | VPC, public + private subnets, IGW, route tables, both DB subnet groups, and the ECR repository the application image lives in. |
| *(root)* | `hbu/<env>/terraform.tfstate` | The RDS instance, its security group, the SSM connection contract, IAM, the ALB and Fargate service running the front end, its two secrets, and the optional bastion and stop/start schedules. |

The per-env stack reads the shared stack's outputs through
`data "terraform_remote_state"`, so it can place a database and a service into
networking it does not own — and `dev` and `prod` differ only by their `.tfvars`
and their state key.

```
              Laptop                        Internet
                 │                              │
                 │ aws ssm start-session        │ :443 — :80 answers a 301
                 │ IAM, no open port, no VPN    │
                 ▼                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│  Shared VPC (10.20.0.0/16)                                             │
│                                                                        │
│  public   SSM bastion (t4g.nano)        ALB ──┐                        │
│           egress only, no key                 │ :8501  everything      │
│                │                              │ :8502  /tiles/*        │
│                │                              ▼ both by security group │
│  public                                 Fargate task                   │
│                │                        Streamlit + the map's tiles    │
│                │ :5432, by security group     │      egress to ECR,    │
│                │                              │      Secrets Manager,  │
│                └──────────────┬───────────────┘      HuggingFace       │
│                               ▼                                        │
│  private  RDS PostgreSQL 16 — no public endpoint                       │
│           postgis · pgvector · pg_trgm                                 │
│                                                                        │
│           rag.chunks       the vector index          DDL: dataplatform │
│           rag.features  ┐                                              │
│           rag.lots      ├ the spatial working set    DDL: this repo    │
│           rag.buildings ┘                                              │
│                                                                        │
│           silver.*  one table per silver asset,      DDL: this repo    │
│           gold.*    partitioned by (neighborhood,    DDL: this repo    │
│                     scrape_date) and upserted                          │
│           warehouse.ensure_partition — creates a leaf on demand        │
└────────────────────────────────────────────────────────────────────────┘
```

"DDL" is the word that matters there: **every row in every one of those tables
is written by hbu_dataplatform.** What this repo owns is the shape — see
[Who owns which table](#who-owns-which-table).

Two things in that picture are the same decision twice. There is deliberately
**no NAT gateway** — it would cost more per month than the database — so
anything needing outbound internet has to sit in a public subnet with a public
IP: the bastion, because its SSM agent dials out to Session Manager, and the
Fargate task, because it pulls from ECR and calls the HuggingFace Inference API
on every question. Neither accepts anything inbound except from a named
security group, so "public subnet" is a routing fact rather than an exposure
one. The longer version is in
[Why the tasks sit in a public subnet](#why-the-tasks-sit-in-a-public-subnet).

The hops inside the VPC are all **security-group references, not CIDRs** — the
ALB to the task on 8501 and on 8502, the task to the database on 5432, the
bastion to the database on 5432. A Fargate task's address is assigned at start
and changes on every deploy, so a CIDR rule could not describe it in the first
place.

The second task port is the map's geometry: the app draws its layers as vector
tiles and Streamlit has no route to serve them from, so a tile server runs on
its own socket in the same container and a listener rule sends `/tiles/*`
there. See [Two ports, two target
groups](#two-ports-two-target-groups-the-maps-tiles).

That is `dev`. **`prod` is still the public posture** — a public endpoint locked
to the applying machine's IP, no bastion, and `enable_app = false` — because
nothing but a laptop talks to it yet; see
[Reachability](#reachability-and-the-tradeoff).

---

## Who owns which table

This is the one thing worth reading before changing any SQL.

`rag.chunks` and `rag.chunks_meta` belong to **hbu_dataplatform**. It creates
them on its first load, from `urban_rag.rag.pgvector`, with the vector width
taken from the parquet it is loading. Nothing in this repo creates or alters
them — two repos issuing slightly different DDL for the same table is exactly
the failure this split avoids.

What this repo owns is everything that table cannot create for itself:

| Object | Why it is here |
|---|---|
| `urban_rag`, `urban_rag_ro`, schemas `rag`, `silver`, `gold`, `warehouse`, `dagster` | Creating a role and the schemas it owns needs the master user, and the master credentials are resolved here |
| `postgis`, `vector`, `pg_trgm`, `pg_stat_statements` | `CREATE EXTENSION` needs `rds_superuser`, which the pipeline's role must not have |
| `rag.features`, `rag.lots`, `rag.buildings` | The spatial working set: the geometry the joins below are computed over, and the geometry the chunks are *about*. `rag.chunks.feature_ids` records which map features cite each document, but it holds ids, not shapes |
| `warehouse.ensure_partition`, `warehouse.partitions` | Creates a `silver`/`gold` leaf on demand, and lists the ones that exist — see [How the silver and gold tables are shaped](#how-the-silver-and-gold-tables-are-shaped) |
| `silver.building_lot_intersections` | Which buildings sit on which lots, computed with `ST_Intersection` — a building spanning several lots gets one row per lot, holding just the clipped slice and its share of the footprint |
| `silver.lot_features` | Which map features cover which lot — the same clip one layer over, and the hop that gives a lot its documents. A lot has no zoning id to link on: the cadastre is provincial (Infolot, `NO_LOT`) and the zoning is municipal (Spectrum, `NUMERO_COMPLET`), so the two are joined by geometry or not at all |
| `silver.neighborhood_streets` | The sides of the roadway, from Montreal's *géobase double* — one row per `COTE_RUE_ID`, already clipped to a borough by the pipeline. Lines, so `length_m` rather than `area_m2` |
| `silver.lot_frontage` | How much of each lot's boundary faces each street side, in metres. Measured on `ST_Boundary(lot)` and not on the lot itself — `ST_Length` of a polygon is 0 — by matching each ~1 m piece of the boundary to its nearest street side within `buffer_m` and keeping the pieces that run within 45° of parallel to it. `frontage_rank = 1` is the street a lot mostly fronts on. Rows whose `buffer_m` is `3.0` predate 2026-08 and were measured by clipping to a buffered street instead, which missed 90 % of a borough's lots and inflated the rest — see the file header |
| `silver.vacancy_rates`, `silver.quartier_vacancy_rates`, `silver.average_rents`, `silver.quartier_average_rents` | One borough's CMHC Rental Market Survey, and the quartier rows each borough figure was averaged over. The average is unweighted — the survey publishes rates and nothing to weight them by — so `num_quartiers` travels on every row as the denominator it was actually taken over |
| `silver.document_chunks` | The corpus before it is embedded: the text, the token count, and which map features cite it. Every scrape date, unlike `rag.chunks`, which is pruned to the current one |
| `silver.zoning_grid_columns`, `silver.lot_zoning_envelopes` | What a *grille des usages et des normes* states, at the zone's grain and joined to the lots that zone covers. `solver_ready` says whether the parse survived contact with the solver |
| `silver.assessment_units` | Every assessed property as the province describes it — one row per *unité d'évaluation* from Quebec's *rôle d'évaluation foncière*, carrying its point, its use code, land and floor area, storeys, year built, dwellings, and the land/building halves of its assessed value. The row-level record `silver.lot_assessed_values` aggregates: that table says what a lot is worth, this one says what is on it. The roll has no borough axis — it is published once for the province — so unlike every other table here its partitions are filled several at a time, by the borough each unit's **point falls inside**; the roll's own `arrond` is kept beside it as a cross-check and never partitioned on. The forty MAMH-coded fields this platform does not name land in `attributes` |
| `silver.lot_assessed_values` | What each lot is assessed at, from Quebec's *rôle d'évaluation foncière* — the units the roll's own cadastre crosswalk places on the lot, plus (for the divided co-ownerships it cannot place, since those name private lots Infolot does not draw) the ones whose point falls in it. **Two totals**: `total_assessed_value` counts each unit whole on every lot it covers and must not be SUM()ed across lots; `total_assessed_value_apportioned` divides by the lots covered and is the one that adds up. `num_shared_units` is where they differ, `num_units_by_point` how many rows came from the fallback, and both totals are **null**, not 0, on a lot no unit reaches — a lane is not worth nothing, it is unassessed |
| `gold.lot_profiles` | Every lot in a borough at the grain a question is asked about — one row per parcel, carrying whether a building stands on it and how many, its primary and secondary street frontage, the document that governs it, the zoning envelopes that bound what may be built on it (`zoning_envelopes`), what the ground on it is assessed at from Quebec's rôle (`total_assessed_value`, with `total_assessed_value_apportioned` as the one that may be summed across lots, and `num_assessment_units` beside them because a condominium's common-parts lot carries one unit per apartment), the borough's CMHC vacancy and rent grids (`vacancy_rates`, `average_rents`) and what it costs to build there (`construction_costs`, with the underground and integrated ground-level parking rates flattened into `underground_stall_cost_low/high_cad` and `above_grade_stall_cost_low/high_cad` — dollars per stall — and the configured condominium / apartment band into `condo_cost_low/high_cad_sqft`). The three joins above each hold one row per (lot × something); this is where they collapse onto the lot, alongside `silver.lot_assessed_values` — already one row per lot, so a plain `LEFT JOIN` on `lot_number` — and four more jsonb columns the dataplatform hands in from its geoparquet tree. Replaces an earlier `rag.vacant_lots`, which kept only the parcels it found nothing on and so could answer one question at the cost of hiding every other lot — `WHERE NOT has_building` is that selection now |
| `rag.chunk_features`, `rag.search_near`, `rag.search_at_lot` | The joins from geometry to vectors |
| `rag.lot_documents`, `rag.search_at_lot_number` | The same joins entered from a lot number rather than a point, off the precomputed `silver.lot_features` |

Every `silver.*` and `gold.*` table is filled by **hbu_dataplatform** through
`urban_rag.warehouse`, which is their single writer; the three `rag.*` tables
are filled by `urban_rag.postgis`, the same repo one layer down.

The role, the schemas and the grants are [`sql/000_roles.sql`](sql/000_roles.sql).
It sorts first, so `db-init` applies it ahead of everything else; `db-bootstrap`
applies it too and then sets the role's password, which is the one thing no
`.sql` file here carries. It used to live in hbu_dataplatform, which meant a
cross-repo `--file` path and two half-bootstraps that each assumed the other
had granted what it needed.

Everything in `rag`, `silver`, `gold` and `warehouse` ends up owned by
`urban_rag` whichever order the steps run in: every file here hands ownership
over at the end if the role exists, and emits a `NOTICE` if it does not.

The `dagster` schema is the exception to the "this repo owns the DDL" rule
above, and it is the same exception `rag.chunks` is: `hbu_dataplatform` points
Dagster's run, event and schedule storage there, and Dagster creates and
migrates those tables itself. What `000_roles.sql` does is make the schema
exist and stay usable no matter which role connects first — the master user
(`db.py env`) and `urban_rag` (`db.py env --app`) both create tables Dagster
can go on using, because the file grants and sets default privileges in both
directions. `db.py check` lists what has landed there; empty until the first
Dagster start, and empty forever if the pipeline is left on the local SQLite
default.

### How the silver and gold tables are shaped

Every table in `silver` and `gold` is partitioned the same way, because every
one of them holds the same thing — one borough's snapshot of one day:

```
<table>                        PARTITION BY LIST  (neighborhood)
  <table>__vsmpe               PARTITION BY RANGE (scrape_date)
    <table>__vsmpe__202608     one month of it
```

The borough set is small, closed and named, so LIST says exactly what it means
and a borough's whole history is one subtree an operator can detach. The date
axis is open and grows a row every day, so it is RANGE, by month.

Postgres requires a partitioned table's unique constraint to contain its
partition keys, which is not a tax here but the grain restated — and it is
exactly what the pipeline's write conflicts on:

```sql
INSERT INTO silver.neighborhood_streets (...)
VALUES (...)
ON CONFLICT (scrape_date, neighborhood, cote_rue_id)
DO UPDATE SET ...
```

A write is that upsert followed by a prune of the partition's rows the load did
not produce. The upsert is what lets a re-run land while readers are querying —
nothing is ever missing mid-load, the way a delete-then-insert leaves it — and
the prune is what keeps snapshot semantics, which the upsert alone cannot: a lot
that disappears from the cadastre has no row to conflict with.

Partitions are created on demand by `warehouse.ensure_partition`, called with
the (neighborhood, scrape_date) about to be written. Deliberately **not** a
`DEFAULT` partition: rows that land in a default cannot be moved by attaching
the partition they belong in, so a default that quietly catches a borough
nobody declared is a table that has to be rewritten to repair.

`make db-check` prints one row per leaf, under `partitions`, which is the read
to run before detaching or dropping anything:

```
partitions (silver + gold leaves)
table_schema  table_name                  partition                                    rows   size
silver        building_lot_intersections  silver.building_lot_intersections__vsmpe__…  18402  24 MB
silver        lot_frontage                silver.lot_frontage__vsmpe__202608            4812   6 MB
gold          lot_profiles                gold.lot_profiles__vsmpe__202608             12907  31 MB
```

### What moved out of `rag`, and what it means for an existing database

Five tables used to live in `rag` and are now the silver or gold table of the
asset that produces them:

| was | is |
|---|---|
| `rag.building_lots` | `silver.building_lot_intersections` |
| `rag.lot_features` | `silver.lot_features` |
| `rag.streets` | `silver.neighborhood_streets` |
| `rag.lot_frontage` | `silver.lot_frontage` |
| `rag.lot_profiles` | `gold.lot_profiles` |

`db-init` creates the new ones and **leaves the old ones exactly where they
are**, holding whatever they last held. Dropping a table that still has
partitions nobody has backfilled is not a decision a migration should make on
its own, so each new file carries the statement commented out in its header:

```sql
DROP TABLE IF EXISTS rag.building_lots;
```

Run those by hand once the boroughs you care about have been re-materialized.
Until you do, an old table is a copy that no longer updates — which matters for
`rag.building_lots` in particular, because `hbu_rag_map` used to read it and now
reads `silver.building_lot_intersections`.

Four things changed with the move, all of them forced by declarative
partitioning and none of them a loss:

- **the `bigserial` primary keys are gone.** A partitioned table's primary key
  has to contain the partition keys, and a surrogate no reader ever cited was
  the wrong half to keep.
- **`lot_number` and `cote_rue_id` are carried down** onto the rows that used
  to join back to `rag.lots` or `rag.streets` for them. Both are publishers'
  own keys, and they are what survives a reload; the `*_uid` columns are
  serials the next load mints again.
- **`street_uid` is gone entirely**, not just demoted. It could not stay a
  serial primary key, and it could not become an identity column either:
  PostgreSQL does not allow those on a partitioned table before 17, and this
  instance is 16. Nothing needed it — `cote_rue_id` is unique across the island
  and is what `silver.lot_frontage` already denormalised.
- **`silver.lot_frontage` has no foreign key on the street side.** Its parent is
  partitioned now, and a foreign key can only reference a unique constraint —
  which on a partitioned table must contain the partition keys, so `cote_rue_id`
  alone cannot be one. The pairing is enforced by the partition instead: both
  tables are keyed on `(scrape_date, neighborhood, …)`, and the join that fills
  one runs inside a single partition of both. The foreign keys that point at
  *unpartitioned* parents — `rag.lots`, `rag.buildings` — are kept, cascade and
  all.

---

## First-time setup

```bash
make db-deps           # boto3 + psycopg for scripts/db.py
```

`AWS_PROFILE` no longer needs exporting — the Makefile pins it to
`charles_gauvin_east_1` (account `038083667790`, where this stack lives) and
exports it to every target. Pass `AWS_PROFILE=<other> make ...` to override, and
`AWS_ACCOUNT=<id>` with it, because every AWS-touching target runs `aws-check`
first and refuses to continue unless the active credentials really are in
`AWS_ACCOUNT`. That check exists because the alternative is silent: with the
wrong credentials, both the state bucket and the `/hbu-<env>` parameter
namespace resolve against an account where none of it exists, and the first
symptom is an `AccessDenied` several steps in. Two ways to end up there — a
shell exporting `AWS_PROFILE=` (empty still counts as set, so the pin used to
fall through to the default profile) and a stray `AWS_ACCESS_KEY_ID` pair, which
botocore reads *before* it ever looks at `AWS_PROFILE` — are both handled in the
Makefile now; the keys behind the profile going stale is not, and shows up as
`aws-check` reporting `InvalidClientTokenId`. Set `AWS_USE_ENV_CREDS=1` to keep
credentials from the environment instead of a profile.
`make db-deps` installs into whichever virtualenv is active and creates one when
none is — `.venv` under Linux and WSL, `.venv-win` in a native Windows shell. A
venv bakes in its layout and the absolute path of the interpreter that built it,
so one directory cannot serve both kernels; whichever shell ran `db-deps` last
would own it. `db-deps` installs uv first if uv is missing — there is no pip
fallback, because a uv-made venv has no pip. Every `db-*` target then runs
`scripts/db.py` with that venv's interpreter, so no `python3` on PATH is
required.

### The whole thing, in order

Database and front end are one sequence, not two: the shared stack creates the
VPC *and* the image registry, and the app's secrets do not exist until the apply
that creates the database has also created them.

```bash
make bootstrap                        # 1. state backend, once per account
make plan-shared apply-shared         # 
#2. VPC + ECR, once
make app-push     ENV=dev             # 3. an image for the service to start on
make plan apply   ENV=dev             # 4. database, ALB, service, both secrets

make db-tunnel    ENV=dev             # 5. another shell, left running
make db-wait      ENV=dev TUNNEL=1
make db-ca
make db-bootstrap ENV=dev TUNNEL=1    #    roles, grants, the role's password
make db-init      ENV=dev TUNNEL=1    #    extensions, the four schemas, every table
make db-check     ENV=dev TUNNEL=1

make app-password ENV=dev             # 6. the two secrets, then roll to pick
make app-hf-token ENV=dev             #    them up
make app-deploy   ENV=dev
make app-url      ENV=dev
```

Two of those positions are load-bearing rather than stylistic:

- **`app-push` before the first `apply`.** `dev.tfvars` already has
  `enable_app = true`, so that apply starts the service — and a service cannot
  reach a steady state against a tag that is not in ECR yet. This is also why
  `enable_app` *defaults* to `false`: it is the only value that makes a first
  apply safe in an environment whose tfvars has not been thought about.
- **`app-password` after it, not before.** Both secret targets resolve the ARN
  from a Terraform output, and the secret does not exist until the apply that
  creates it. In between, the app is up holding `PLACEHOLDER` in both: it
  serves the login form and refuses every password, which
  [`auth.py`](../hbu_rag_map/src/utils/auth.py) does deliberately and says so.

Steps 5 and 6 are independent of each other. The app cannot answer a question
until the database has been bootstrapped, but neither sequence waits on the
other, and the tunnel in step 5 has nothing to do with the app.

### 1. State backend (once per account)

```bash
make bootstrap         # local state; creates hbu-tf-state-<account> + hbu-tf-locks
```

### 2. Shared VPC and the image registry (once)

One apply, two consumers: the networking every other stack places things into,
and the ECR repository `make app-push` pushes to. It is the one step the
database and the front end genuinely share.

```bash
make plan-shared
make apply-shared
```

### 3. An image to start against

Built from `../hbu_rag_map` and pushed to the repository step 2 created. It has
to exist before the apply that turns the service on.

```bash
make app-push ENV=dev             # builds and pushes :latest
```

`dev` tracks the moving `:latest`; `prod` pins an immutable tag, because `latest`
moving under a running service is convenient in one and exactly what you do not
want in the other.

### 4. The database, the load balancer and the service

```bash
make plan  ENV=dev
make apply ENV=dev
```

`dev` comes up with no public endpoint, so everything database-side after this
goes through the tunnel: one shell holds it open, the rest of the work happens
in another.

```bash
make db-tunnel ENV=dev            # leave running; Ctrl-C closes it
make db-wait   ENV=dev TUNNEL=1   # RDS takes ~5–10 min to come up
```

Every `db-*` target takes `TUNNEL=1`, which swaps the address for
`localhost:5433` and resolves the credentials from AWS exactly as before.

`prod` still sets `allow_current_ip = true`, which allowlists the applying
machine's public address — re-apply there after your ISP hands you a new one.

### 5. Bootstrap the database

Both steps apply `000_roles.sql`, so the order does not affect who owns what.
What only `db-bootstrap` does is set the role's password: until it has run,
`urban_rag` exists but cannot log in.

```bash
make db-ca                             # RDS root cert, for sslmode=verify-full
make db-bootstrap ENV=dev TUNNEL=1     # urban_rag role + grants, password → Secrets Manager
make db-init      ENV=dev TUNNEL=1     # extensions, the rag/silver/gold schemas and their tables
make db-check     ENV=dev TUNNEL=1
```

`db-init` will report two files skipped:

```
003_spatial_search.sql skipped — rag.chunks does not exist yet
006_lot_documents.sql  skipped — rag.chunks does not exist yet
```

That is expected, not a fault: both build views and SQL-language functions over
the dataplatform's `rag.chunks`, and a function body is parsed at `CREATE` time,
so neither can be created before that table exists. Materialize `document_index`
over there, then run `make db-init` once more to create them. Everything else —
the extensions, the `rag` working set, and every `silver`/`gold` table — lands
on this first run, which is what the pipeline needs to write anything at all.

### 6. The front end's two secrets

Step 4 created both holding `PLACEHOLDER`, and Terraform will never touch their
contents again. These write the real values straight to Secrets Manager:

```bash
make app-password ENV=dev         # the shared access password (prompts)
make app-hf-token ENV=dev         # the Inference API token (prompts)
make app-deploy   ENV=dev         # tasks read secrets at start, so roll them
make app-url      ENV=dev         # where it ended up
make app-dns      ENV=dev         # the record to point a domain at it
```

Why they are shaped that way, and what the password does and does not protect,
is in [The web application](#the-web-application) below.

Afterwards a code change is two commands — `make app-push app-deploy ENV=dev`.
`app-deploy` forces a new deployment of the *same* task definition, which is
what picks up a moved `latest`. A change to the task itself — CPU, memory, a
new environment variable — is a `terraform apply`, not `app-deploy`.

---

## Talking to the database

Nothing below takes a hostname or a password. Terraform publishes the
connection details to SSM under `/hbu-<env>/db/*`, RDS keeps the master
password in Secrets Manager and rotates it, and
[`scripts/db.py`](scripts/db.py) resolves both at call time — so none of these
break when the instance is replaced.

```bash
make db-tunnel ENV=dev                    # one shell, left running

make db-shell  ENV=dev TUNNEL=1           # interactive SQL (psql if installed, REPL if not)
make db-check  ENV=dev TUNNEL=1           # extensions, tables, partitions, corpus, index metadata
make db-query  ENV=dev TUNNEL=1 SQL="select * from rag.corpus_status"
make db-url    ENV=dev TUNNEL=1           # a localhost URL for QGIS, DBeaver, psycopg
eval "$(make -s db-env ENV=dev TUNNEL=1)" # PG* and URBAN_RAG_PG_* in the shell
eval "$(make -s db-app-env ENV=dev)"      # the pipeline's role, password via Secrets Manager
```

`TUNNEL=1` swaps the address for `localhost:5433` and nothing else —
the credentials, the database name, and the instance id still come from AWS. It
is required for `dev`, which has no public endpoint, and pointless for `prod`,
which does. Pass `LOCAL_PORT=<n>` to both targets to use a different port.
`db-app-env` never needs it: it is read by things running inside the VPC, which
reach the endpoint directly.

`db.py` is importable too, which is the point of the `connect` helper:

```python
from db import connect
with connect(env="dev") as conn:
    ...
```

Set `DATABASE_URL` to bypass AWS resolution entirely — a local
`postgis`+`pgvector` container, or an already-open tunnel. Append
`?sslmode=disable` for a container that speaks no TLS.

### The password never being in Terraform state

`manage_master_user_password = true` hands the master password to RDS, which
generates it, stores it in Secrets Manager, and owns rotation. Terraform never
sees it, so it cannot leak through the state file — which is the usual way a
database password ends up in an S3 bucket.

The `urban_rag` role's password is generated by `db.py bootstrap` and written
to a secret Terraform creates but never fills; `ignore_changes` keeps a later
apply from reverting it to the placeholder. IAM authentication is enabled on
the instance as an alternative, for the path where nothing stores a password at
all — the role still needs `GRANT rds_iam`, which is commented out in
[`sql/000_roles.sql`](sql/000_roles.sql).

### Getting the DB credentials

Use the helper instead of pasting the RDS secret ARN. It resolves the current
secret from SSM, fetches it from Secrets Manager, and adds `password_urlencoded`
plus a ready-to-copy `database_url` whose password is percent-encoded:

```bash
make db-secret ENV=dev
```

For just the encoded connection URL, `make db-url ENV=dev` prints the same
`postgresql://...` form directly.

### QGIS credentials

After

```
make db-tunnel ENV=dev    
```

and fetching the password using the procedure above, fill in the following values in the postgres connection to access the DB on QGIS:

```
Host: 127.0.0.1
Port: 5433
Database: urban_rag
SSL mode: require
Username: hbu_admin
Password: <actual password from Secrets Manager>
```

---

## Spatial retrieval

The reason for the whole arrangement. Both functions take an embedding your
client produces, so nothing server-side loads a model.

```sql
-- What the corpus says near a point, ranked by similarity within 500 m
SELECT chunk_id, distance_m, similarity, chunk_text
  FROM rag.search_near('[...]'::vector, -73.619, 45.541, 500, 5);

-- Everything that applies to the lot a point falls in
SELECT lot_number, chunk_id, similarity, chunk_text
  FROM rag.search_at_lot('[...]'::vector, -73.619, 45.541, 5);
```

`ST_DWithin` over `geography` casts the radius to metres and still uses the
GiST index, so the candidate set is "chunks whose document is cited by a
feature near this point" and only those get ranked.

One consequence worth knowing: because the spatial filter runs first and is
selective, the planner will usually scan the surviving chunks rather than use
the HNSW index. That is the right plan — an approximate index over a handful of
rows costs more than reading them — and it means recall in `search_near` is
**exact**, unlike an unfiltered vector search.

### Reading the pipeline's own tables

Those two functions answer from a point. The silver and gold tables answer from
a parcel, and need no embedding at all:

```sql
-- The vacant land in one borough on one day, widest street edge first
SELECT lot_number, lot_area_m2, primary_frontage_m, primary_street_name
  FROM gold.lot_profiles
 WHERE neighborhood = 'VSMPE' AND scrape_date = '2026-08-26'
   AND NOT has_building
 ORDER BY primary_frontage_m DESC
 LIMIT 20;
```

Always filter on **both** partition columns when you know them. That predicate
is what prunes the query to one leaf — `silver.…__vsmpe__202608` — instead of
scanning every borough-month the table has ever held; `EXPLAIN` will show a
single partition scanned when it works. Everything downstream is a join inside
that partition:

```sql
-- What each zone permits on one lot, and whether the solver could take it
SELECT e.feature_id, e.column_index, e.floors_max, e.height_max_m,
       e.governs_residential, e.solver_ready, e.solver_error
  FROM silver.lot_zoning_envelopes e
 WHERE e.neighborhood = 'VSMPE' AND e.scrape_date = '2026-08-26'
   AND e.lot_number = '1 234 567'
 ORDER BY e.pct_of_lot DESC, e.column_index;
```

`urban_rag_ro` can read all of it: `000_roles.sql` grants `SELECT` on `rag`,
`silver` and `gold`, and sets default privileges so a partition created next
month is readable without anyone re-granting anything.

---

## Reachability, and the tradeoff

`dev` runs the **private posture**: the instance sits in subnets with no route
off the VPC, it has no public endpoint, and its security group names no CIDR at
all — the only ingress is the bastion's security group.

```hcl
db_subnet_tier         = "private"
db_publicly_accessible = false
allow_current_ip       = false
enable_bastion         = true
```

`make db-tunnel ENV=dev` port-forwards 5432 to `localhost:5433` through Session
Manager — no SSH key, no open port, no VPN. Access is IAM, revoked by removing a
permission rather than by rotating a key that is already on three laptops, and
nothing is pinned to a home IP address, so a new one from your ISP costs
nothing.

`prod` is still the **public posture**: a public endpoint whose security group
lists exactly one CIDR, the applying machine's. It is the posture in which every
command works from a laptop with nothing else set up, and `rds.force_ssl = 1`
means the traffic is TLS whatever the client asks for. It is also still a
database on the public internet.

### The tunnel supervises itself

A raw port-forward is not durable enough to run a pipeline through, and the way
it fails is worse than the failing.

Session Manager closes an idle session after about 20 minutes — 60 at the
absolute most, and that ceiling is account-wide, set on the
`SSM-SessionManagerRunShell` preferences document. `setbacks` is 53 minutes of
one server-side PostGIS statement, and `programs` is a ~16-minute CP-SAT solve.
For all of that time the client is waiting on a query and this port carries no
traffic, so the session idles out from under a job that is working perfectly.

When it does, `session-manager-plugin` **keeps running and keeps its listener**.
The port stays open. `connect()` still succeeds. Nothing ever comes back. Every
client after that blocks for its full `connect_timeout` and then reports
something that reads like a slow database — and `hbu_rag_map`'s pool, which
hardcodes `timeout=15.0`, raises `PoolTimeout` while libpq is still waiting. A
dead tunnel and a healthy one are indistinguishable from the client, which is
why this cost so many hours before it was named.

So `scripts/tunnel.sh` supervises the session rather than `exec`ing it:

- a health probe every `TUNNEL_KEEPALIVE_INTERVAL` seconds (120 by default),
  which doubles as the keepalive — the traffic it generates is what stops the
  session idling out in the first place;
- a failed probe tears the session down and reconnects, with backoff to a
  60-second ceiling, so a suspended laptop comes back to a poll rather than to a
  hot loop;
- the bastion instance id is re-resolved on every reconnect, because a
  stop/start gives it a new one;
- a preflight that refuses to start when something already holds the port, and
  names the process holding it instead of leaving the plugin to report
  "Address already in use" long after the context that would explain it.

The local address does not change across a reconnect, so a `psql` or a Dagster
run that is merely *idle* survives one. It does **not** rescue an in-flight
query: a reconnect drops the TCP connections through it, and whatever was
running gets a closed connection and has to retry. What it fixes is the tunnel
not being there afterwards.

#### The probe is an SSLRequest, not a connect

"Is the port open" is not a health check, for the reason above. Only a round
trip to the far end is. The probe sends Postgres' `SSLRequest` — eight bytes,
length 8 and request code 80877103 — to which any live server replies with a
single byte: `S` if it will do TLS, `N` if it will not.

It needs no credentials, so it cannot fail for a reason that has nothing to do
with the tunnel, and it holds no connection open. Against the dead session that
was found holding port 5433 while this was being written, a plain TCP connect
succeeded and the SSLRequest timed out with no reply — which is exactly the
discrimination that was wanted.

Its one cost is server-side noise: the probe hangs up after reading the reply
rather than completing a handshake, and Postgres logs that as a failed SSL
connection — roughly 700 lines a day into the instance's CloudWatch log group at
the default interval. Raise `TUNNEL_KEEPALIVE_INTERVAL` if that matters more
than detecting a dead session quickly.

#### Reading it, and turning it off

```
$ make db-tunnel ENV=dev
tunnelling hbu-dev.…rds.amazonaws.com:5432 -> 127.0.0.1:5433 via i-05307ac744d9086ec
08:45:21  up on 127.0.0.1:5433 — probing every 120s, Ctrl-C to close
09:31:44  keepalive probe got no answer — the session is dead upstream
09:31:47  reconnecting in 5s (attempt 1)
09:31:55  up on 127.0.0.1:5433 — probing every 120s, Ctrl-C to close
```

Status goes to stderr; the plugin's own banner and its one line per accepted
connection are captured to `$TMPDIR/hbu-tunnel-<env>-<port>.log` and printed
only when a session fails to come up — which is where the real reason lives,
since an expired SSO session says so there and nowhere else.

| Variable | Default | |
|---|---|---|
| `TUNNEL_SUPERVISE` | `1` | `0` runs a single foreground session, the old behaviour. For when the plugin itself is what is being debugged. |
| `TUNNEL_KEEPALIVE_INTERVAL` | `120` | Seconds between probes. |
| `TUNNEL_READY_TIMEOUT` | `60` | Seconds a new session gets to open the port and answer. |
| `TUNNEL_PROBE_TIMEOUT` | `10` | Seconds one probe waits for its reply. |
| `TUNNEL_BACKOFF_MAX` | `60` | Reconnect backoff ceiling. |

All five are forwarded across the WSL re-exec, and only when actually set — an
empty `TUNNEL_SUPERVISE=` is not `1`, and forwarding it unconditionally would
have silently disabled supervision for every Windows caller.

Two notes for anyone editing this script. It runs under `set -euo pipefail`,
and the combination is hostile to a supervisor: `pgrep` matching nothing exits
1, `pipefail` carries that through a pipe, and a failed command substitution in
an assignment trips `errexit` — so the supervisor exits(1) at precisely the
moment it was supposed to reconnect. That bug was in the first version of this
and is why `kill_session` and `resolve_target` carry explicit `|| true` and
`|| BASTION_ID=`. And `pkill -f 'ssm start-session'` matches *its own shell*;
kill by PID.

### Why the public posture is not an option from this laptop

The obvious simplification — give `hbu-dev` a public endpoint and allowlist a
home IP, which is what `prod.tfvars` already does and what `db_subnet_tier` and
`allow_current_ip` already support — does not work from this machine, and the
reason is on the client side rather than in AWS.

Measured 2026-09-01, from the workstation this repo is developed on:

| Outbound TCP | Result |
|---|---|
| 80 | HTTP 200 in 0.49s |
| 22 | HTTP 200 in 0.31s — **open** |
| 443, non-TLS payload | connection **reset** in 0.23s (the proxy expects a `ClientHello`) |
| 5432 | **silently dropped** — timed out at 12s, 20s and 20s on three tries |
| 8080 | **silently dropped** — timed out at 15s |

Zscaler Client Connector (`ZSATunnel`, `ZSAService`) is running, and the policy
is not "web only": **22 is open, database ports are not**. It looks like a
deliberate rule against reaching databases directly rather than a blanket
restriction, which matters, because it means SSH to an instance is a route that
works while a public endpoint is not.

A public endpoint on 5432 would still be unreachable — the packets never leave
the laptop, so no security-group change can help. Moving the instance to port
443 does not rescue it either: libpq opens with an 8-byte `SSLRequest`, not a
TLS `ClientHello`, so the proxy resets it exactly as it reset the probe above.

This is enforced by an agent on the endpoint, so it follows the laptop to any
network. The HTTP egress address is a residential one (`AS1403 EBOX`,
Montréal), not a Zscaler datacenter range, so allowlisting *would* be
well-scoped if the port were open — the obstacle is only the port.

SSM is not incidental complexity here. It rides 443 to an AWS endpoint the proxy
already allows, which is why it is the one thing that works. Changing that needs
a Zscaler bypass for the RDS endpoint on 5432, which is an IT request rather
than a Terraform change; the Terraform half is three lines in `dev.tfvars` and
is already written and tested by `prod`.

### Changing tier replaces the instance

Not modifies — replaces. `ModifyDBInstance` accepts a new DB subnet group only
when it moves the instance to a *different* VPC; inside one VPC it answers:

```
InvalidVPCNetworkStateFault: You cannot move DB instance hbu-dev to subnet group
hbu-private. The specified DB subnet group and DB instance are in the same VPC.
```

The AWS provider does not model that, so the change plans as a clean in-place
update and then fails half way through the apply — after, in the case that
prompted this note, the old CIDR rule had already been destroyed.
`terraform_data.db_subnet_tier` in [`rds.tf`](rds.tf) exists to keep the plan
honest: the tier feeds a `replace_triggered_by`, so changing it shows up as the
replacement it is. The *first* move still needs `-replace` by hand, since a
trigger created in the same apply has no previous value to differ from:

```bash
terraform plan -var-file=dev.tfvars -replace=aws_db_instance.main -out=tfplan
terraform apply tfplan
```

Budget ~15 minutes, and re-run `db-bootstrap` and `db-init` afterwards: the new
instance is empty and its master password is a new secret. Nothing has to be
edited by hand — the SSM contract and the IAM policy's `rds-db:connect` resource
are all derived from the resource, so they re-publish themselves.

Terraform will warn (not fail) if you turn off both the public endpoint and the
bastion, since that leaves nothing outside the VPC able to connect — a fine end
state once ECS is talking to it, and a confusing one before.

---

## The web application

`hbu_rag_map` is packaged as a container and runs on Fargate behind the load
balancer in the diagram above. Standing it up for the first time is steps 3, 4
and 6 of [First-time setup](#first-time-setup); this section is the *why* behind
the parts of that sequence that otherwise look arbitrary.

### Why the tasks sit in a public subnet

Every chat turn and every query embedding is an outbound HTTPS call to the
HuggingFace Inference API, and the image is pulled from ECR over the internet.
With no NAT gateway in this VPC, a task in the private tier can do neither.

The alternatives were both worse here. A NAT gateway is ~$32/mo before data
processing — more than the database it would sit beside. Interface endpoints
for ECR, S3, logs and Secrets Manager are cheaper than that but solve only the
pull: nothing reaches `huggingface.co` through them, so the app would start and
then fail on its first question.

"Public subnet" is a routing fact, not an exposure one. The task security group
accepts inbound **only** from the ALB's security group, so the public IP
carries egress and answers nothing.

### Two ports, two target groups: the map's tiles

The app serves on one port and the map's geometry on another, and the ALB has
a rule that separates them. It is worth explaining because "one service, two
target groups" is unusual enough to look like an accident.

`hbu_rag_map` draws its lots, footprints, zones and massing as Mapbox Vector
Tiles rather than as GeoJSON embedded in the page — that repo's README has the
why, and the short version is that a page carrying a borough's cadastre is a
page that stops responding. Leaflet fetches those tiles over HTTP from inside
the map, and **Streamlit serves no routes of its own**, so the app runs a small
tile server on a second socket in the same process. This stack's whole job is
to put that socket somewhere the browser can reach it:

```
                 ALB listener
                      │
       ┌──────────────┴───────────────┐
   /tiles/*                      everything else
       │                              │
  tiles TG :8502                 app TG :8501
       └──────────── same task ───────┘
```

One task, registered twice. Not a second service, because the tile server *is*
the app process: it borrows the same connection pool, the same resolved
endpoint, the same `verify-full` posture, and it would gain nothing from a
container of its own but a second copy of all of that to keep in step.

**The two target groups are configured as opposites, and every difference is
one fact read twice: a tile request is stateless.** The app's group is sticky,
because session state lives in a task's memory and a reconnecting websocket has
to land back on it. The tile group is not, because a tile is a pure function of
its URL — pinning them would only bunch every tile onto whichever task the
first request happened to reach. It health-checks `/tiles/healthz` rather than
`/_stcore/health`, and drains in ten seconds rather than thirty, since a tile
is milliseconds and not a streamed answer.

**A listener rule does not make the tiles public.** Every tile URL carries a
key `hbu_rag_map` derives from the same `HBU_APP_PASSWORD` this stack injects
from Secrets Manager — an HMAC of it, never the password — and the tile server
refuses a request without one. That is what keeps a path rule from putting the
cadastre and a solved development programme on the internet. It is *derived*
rather than random precisely so every task computes the same one, which is what
makes the missing stickiness above safe. `/tiles/healthz` is the only path
outside the check, because a health check carries no credentials.

`HBU_TILE_BASE_URL` is set to the empty string in the task definition, and that
is the whole of what tells the app it is behind a load balancer: the tile URLs
come out relative (`/tiles/lots/{z}/{x}/{y}.mvt`), so they resolve against
whatever DNS name the ALB is reached by and nothing in this repo has to know
it. A laptop leaves the variable unset and gets an absolute
`http://localhost:8502` instead, because there Streamlit and the tiles really
are two origins.

`app_tile_port` and `app_tile_path_pattern` are the two knobs. The port has to
agree with the container's `HBU_TILE_PORT`, which the task definition also
sets, so there is one number in one place.

**Checking it after a deploy:** `terraform output app_tiles_health_url` and
fetch it. A 200 says the rule reaches the task's second port. A tile itself
needs the key, so that path is the only part of the endpoint that answers
unauthenticated — which makes it exactly the right thing to curl.

### HTTPS, and pointing a domain at it

`app_certificate_arn` is the whole switch. Empty, the ALB is a single port 80
listener. Set to an ACM certificate **in the same region as the load balancer**,
it adds a 443 listener on `ELBSecurityPolicy-TLS13-1-2-2021-06` and turns 80
into a 301 to it — in place, without replacing the load balancer or changing
its DNS name, so it is safe to flip on a running service.

`dev` is set, to a certificate in `us-east-1`. `prod` is still empty, which
costs nothing while `enable_app = false` and is the first thing to fix when
that flips.

TLS ends at the listener. The ALB talks to the task over plain HTTP inside the
VPC, which is the normal arrangement and is why the target group is `HTTP` on
8501 — the hop is between two security groups in one VPC, and terminating
twice would mean managing a certificate the tasks would have to carry.

The certificate is why the load balancer now needs a **name**. A public CA
cannot issue for `*.elb.amazonaws.com`, so opening the ALB's own DNS name over
HTTPS warns however valid the certificate is. Point a name the certificate
covers at it instead:

```bash
make app-dns ENV=dev              # the record, spelled out
terraform output -raw app_dns_target    # just the hostname
```

An ALB has no fixed address — AWS moves it between IPs as it scales — so this
is never an A record holding an IP. Two shapes, depending on where the zone
lives:

| Zone | Record |
|---|---|
| Anywhere (Cloudflare, Namecheap, a registrar) | `CNAME app.example.com → app_dns_target`. A CNAME cannot sit at a zone apex, so this has to be a subdomain. |
| Route 53 | An alias `A` record — free, and it works at the apex. Needs `app_dns_target` as the alias name and `app_dns_zone_id` as its zone, which is the **ALB's** hosted zone, not your domain's. |

Terraform does not own the record. The zone is not in this stack and may not be
in this account, so the mapping is a manual step and the outputs exist to make
it a copy-paste one.

Two things that look like breakage and are not. A certificate covering
`app.example.com` does not cover `example.com` or any other subdomain unless it
was requested with those names — ACM does not infer them. And a certificate is
only usable in the region it was issued in: `us-east-1` is special for
CloudFront, not for load balancers — this one works because the ALB is in
`us-east-1` too.

### The password, and what it is not

The app asks for one shared password before it renders anything — checked in
[`src/utils/auth.py`](../hbu_rag_map/src/utils/auth.py), not at the load
balancer, because an ALB cannot do basic auth and Cognito would be a user
directory for a thing that has one credential.

It now travels over TLS: with `app_certificate_arn` set there is no plain-HTTP
path to the form, because port 80 redirects before the page is ever served.
That closes the transport problem and none of the others:

- **It authenticates access, not people.** Nothing records who asked a
  question, and revoking one person's access means changing the password for
  everyone.
- **A redirect is not a guarantee the first request was private.** Someone who
  types `http://` sends that one request in the clear before the 301 — it
  carries no password, but it does carry the URL. HSTS would fix it and is not
  set.
- **It is only as good as where it is kept.** One password shared by hand is
  one password in someone's notes; `make app-password` is cheap, so change it
  when the set of people changes.

A `check` block in [`alb.tf`](alb.tf) warns on every plan where the app is open
to `0.0.0.0/0` with no certificate — a warning rather than an error, because
HTTP-only behind a narrow `app_ingress_cidr_blocks` is a reasonable place to
start. `dev` now satisfies it by having the certificate rather than by
narrowing the CIDR.

### The two application secrets

Both the password and the HuggingFace token follow the pattern
[`ssm.tf`](ssm.tf) established for the app-role password: **Terraform owns the
secret, not the value.** It creates the container, writes `PLACEHOLDER` once,
and then `ignore_changes` keeps it from ever reading or rewriting the contents.

```bash
make app-password ENV=dev     # the shared access password
make app-hf-token ENV=dev     # HuggingFace Inference API token
```

Both prompt, and write straight to Secrets Manager. Nothing about them passes
through a plan, appears in a diff, or lands in the state file in S3 — which is
the same reason the database's master password is `manage_master_user_password`
rather than a Terraform-generated string.

Two consequences worth knowing:

- **A rotation is not live until the service rolls.** A task reads both secrets
  at start, so `make app-password` changes nothing for anyone already running.
  Follow it with `make app-deploy ENV=dev`.
- **A first apply creates a working service with a placeholder password.** The
  app will start and refuse every login until the real value is set, which is
  why both secret commands come before `make apply` in the sequence above.

The task reads them by ARN through the execution role, injected as environment
variables by ECS at start — `ecs.tf` names the secret, never its value. The
ARNs are outputs (`app_password_secret_arn`, `app_hf_token_secret_arn`) if you
need to set one from the console instead.

### The task gets no configuration

The image carries no endpoint, no password, and no environment name. The task
definition sets `HBU_PROJECT` and `HBU_ENV` — the two halves of the SSM prefix
— and `src/utils/db.py` discovers the host, port, database and app-role secret
underneath it. Replacing the RDS instance therefore changes nothing in
[`ecs.tf`](ecs.tf) and needs no redeploy.

It connects with `sslmode=verify-full`, which the image supports because its
Dockerfile bakes in Amazon's RDS root bundle. The alternative, `require`,
encrypts but authenticates nothing — it accepts any certificate presented.

### Operating it

```bash
make app-status ENV=dev            # running/desired, last deployment events
make app-logs   ENV=dev            # tail stdout (SINCE=1h to go further back)
make app-shell  ENV=dev            # a shell inside the running task, over SSM
make app-url    ENV=dev            # the URL, scheme following the certificate
make app-dns    ENV=dev            # the DNS record to point a domain at it
make app-scale  ENV=dev COUNT=0    # stop paying for it without destroying it
```

---

## Cost

Roughly, in `us-east-1`, for the dev defaults:

| | |
|---|---|
| db.t4g.micro, single-AZ | ~$12/mo |
| 20 GiB gp3 | ~$2/mo |
| Backups (1 day, dev) | pennies |
| Bastion t4g.nano + its public IPv4 (on for `dev`) | ~$7/mo |
| ALB, idle (on for `dev` via `enable_app`) | ~$17/mo |
| One Fargate task, 0.5 vCPU / 1 GiB, always on | ~$18/mo |
| The task's public IPv4 | ~$4/mo |
| ECR storage, 10 images | pennies |
| ACM certificate, public | free |

The application roughly triples the bill, and the ALB is most of it — it is
billed by the hour whether or not anyone opens the page. `make app-scale
ENV=dev COUNT=0` stops the Fargate and IPv4 charges without destroying
anything; the ALB keeps billing until `enable_app = false` is applied, which
also releases its DNS name — and with it any CNAME or alias record pointing at
the old one, which has to be repointed after the next `enable_app = true`.

`enable_scheduled_shutdown = true` adds EventBridge schedules that stop the
instance overnight and start it in the morning, through the RDS API directly —
no Lambda. Two things to know before turning it on: **storage and backups are
still billed while stopped**, so it saves instance hours and not the whole
bill; and RDS force-starts anything left stopped for 7 days, which a daily
start cron makes moot but a *paused* schedule does not.

### Sizing is an HNSW question

The index has to fit in memory to be fast: roughly `rows × dimension × 4 bytes`
plus the graph. 1024-wide bge-m3 vectors are ~4 KB each, so the current VSMPE
corpus (~500 chunks) fits a `db.t4g.micro` with room to spare, but 100k chunks
is ~400 MB of vectors before the graph and wants a `db.t4g.medium`. Prod
defaults to medium for that reason.

---

## Files

| File | What it holds |
|---|---|
| [`rds.tf`](rds.tf) | The instance, its parameter group, log group, reachability precondition |
| [`security.tf`](security.tf) | The database security group and who may reach 5432 |
| [`ssm.tf`](ssm.tf) | The `/hbu-<env>/db/*` contract, the app-role secret, the IAM policy for readers |
| [`bastion.tf`](bastion.tf) | Optional SSM jump host (`enable_bastion`) |
| [`schedule.tf`](schedule.tf) | Optional overnight stop/start (`enable_scheduled_shutdown`) |
| [`alb.tf`](alb.tf) | The public load balancer, its security group, the app and tile target groups, the 80/443 listeners `app_certificate_arn` switches between, and the `/tiles/*` rule (`enable_app`) |
| [`ecs.tf`](ecs.tf) | The Fargate cluster, task definition (both ports), service (both target groups), task IAM roles, and the two application secrets |
| [`outputs.tf`](outputs.tf) | Connection details, the app URL, and the ALB's DNS name and zone for a CNAME or alias record |
| [`sql/`](sql/) | Extensions, the `rag` working set, the partitioned `silver`/`gold` tables and the function that creates their partitions, spatial search functions |
| [`scripts/db.py`](scripts/db.py) | The CLI everything above is driven through |
| [`scripts/tunnel.sh`](scripts/tunnel.sh) | Session Manager port forwarding |

### A note on `sql/` ordering

`db.py init` applies every file in `sql/` in **name order**, which is the whole
dependency mechanism — there is no migration table and no version column. The
numbers are what say what has to exist before what:

| File | Creates | Needs first |
|---|---|---|
| [`000_roles.sql`](sql/000_roles.sql) | `urban_rag`, `urban_rag_ro`, the five schemas, the grants | the master user |
| [`001_extensions.sql`](sql/001_extensions.sql) | `postgis`, `vector`, `pg_trgm`, `pg_stat_statements`, and a notice if PostGIS is too old for the map's vector tiles | `rds_superuser` |
| [`002_spatial.sql`](sql/002_spatial.sql) | `rag.features`, `rag.lots`, `rag.buildings` | 001, for `geometry` |
| [`003_spatial_search.sql`](sql/003_spatial_search.sql) | `rag.chunk_features`, `rag.search_near`, `rag.search_at_lot`, `rag.corpus_status` | `rag.chunks` — *skipped until it exists* |
| [`003_warehouse.sql`](sql/003_warehouse.sql) | `warehouse.ensure_partition`, `warehouse.partitions` | 000 |
| [`004_silver_building_lots.sql`](sql/004_silver_building_lots.sql) | `silver.building_lot_intersections` | 002, 003_warehouse |
| [`005_silver_lot_features.sql`](sql/005_silver_lot_features.sql) | `silver.lot_features`, and widens `rag.features`'s uniqueness to the borough | 002, 003_warehouse |
| [`006_lot_documents.sql`](sql/006_lot_documents.sql) | `rag.lot_documents`, `rag.search_at_lot_number` | 005 **and** `rag.chunks` — *skipped until it exists* |
| [`007_silver_streets.sql`](sql/007_silver_streets.sql) | `silver.neighborhood_streets` | 003_warehouse |
| [`008_silver_lot_frontage.sql`](sql/008_silver_lot_frontage.sql) | `silver.lot_frontage` | 002, 007 |
| [`009_gold_lot_profiles.sql`](sql/009_gold_lot_profiles.sql) | `gold.lot_profiles` | 002, 003_warehouse |
| [`010_silver_cmhc.sql`](sql/010_silver_cmhc.sql) | the four CMHC tables | 003_warehouse |
| [`011_silver_corpus.sql`](sql/011_silver_corpus.sql) | `silver.document_chunks` | 003_warehouse |
| [`012_silver_zoning.sql`](sql/012_silver_zoning.sql) | `silver.zoning_grid_columns`, `silver.lot_zoning_envelopes` | 003_warehouse |
| [`013_silver_lot_assessed_values.sql`](sql/013_silver_lot_assessed_values.sql) | `silver.lot_assessed_values` | 001, for `geometry`; 003_warehouse |
| [`014_silver_assessment_units.sql`](sql/014_silver_assessment_units.sql) | `silver.assessment_units` | 001, for `geometry`; 003_warehouse |

`003_warehouse.sql` sorting *after* `003_spatial_search.sql` is name order doing
its job rather than a collision: `s` < `w`, and everything from `004` on needs
the partition function that file creates.

Every file is idempotent, and `db-init` is meant to be re-run: `CREATE ... IF
NOT EXISTS` throughout, ownership handed over at the end of each file guarded on
the role existing, and constraint swaps written as explicit `DO` blocks rather
than as edits to a `CREATE TABLE` that a database already past.

A file may also declare a relation it cannot be *parsed* without:

```sql
-- requires: rag.chunks
```

`db.py` checks that relation with `to_regclass` and skips the file with a note
if it is missing, rather than failing. Two files carry that header today, and
both for the same reason: a SQL-language function body is parsed at `CREATE`
time, so neither can be created before the dataplatform's table exists — and a
hard error on the first run of a new database would be noise rather than
information. Re-run `db-init` after the first `document_index` materialization
and they land.
