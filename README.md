# hbu_infra

Terraform for the **hbu** RAG database: Amazon RDS for PostgreSQL with
**PostGIS** and **pgvector**, plus a single CLI for talking to it.

The corpus and the geometry live in one database on purpose. `hbu_dataplatform`
scrapes Montreal's zoning layers and embeds the PDFs they link to; a
highest-and-best-use question needs both halves at once — *what do the rules
say* is a vector search, *which rules apply here* is a spatial one, and neither
answer is worth much alone.

There is no CI yet. Every apply is manual, and the state backend is the only
thing bootstrapped ahead of it.

---

## Layout

Three stacks, each with its own state, following the same split as
[`ebird-llm/infra`](../ebird-llm/infra):

| Stack | State key | Owns |
|---|---|---|
| [`bootstrap/`](bootstrap/) | *local* | The S3 state bucket and DynamoDB lock table. Applied once. |
| [`shared/`](shared/) | `hbu/shared/terraform.tfstate` | VPC, public + private subnets, IGW, route tables, both DB subnet groups. |
| *(root)* | `hbu/<env>/terraform.tfstate` | The RDS instance, its security group, the SSM connection contract, IAM, and the optional bastion and stop/start schedules. |

The per-env stack reads the shared stack's outputs through
`data "terraform_remote_state"`, so it can place a database into networking it
does not own — and `dev` and `prod` differ only by their `.tfvars` and their
state key.

```
Internet
    │  :5432, only from the CIDRs the security group lists
    ▼
┌──────────────────────────────────────────────────────┐
│  Shared VPC (10.20.0.0/16)                            │
│                                                        │
│  public  ─ RDS PostgreSQL 16                          │
│            postgis · pgvector · pg_trgm               │
│            rag.chunks    ← hbu_dataplatform           │
│            rag.features  ← this repo                  │
│            rag.lots      ← this repo                  │
│                                                        │
│  private ─ (empty; for ECS, when there is an app)     │
└──────────────────────────────────────────────────────┘
```

There is deliberately **no NAT gateway**: nothing in the private tier needs
outbound internet, and a NAT would cost more per month than the database.

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
| `postgis`, `vector`, `pg_trgm`, `pg_stat_statements` | `CREATE EXTENSION` needs `rds_superuser`, which the pipeline's role must not have |
| `rag.features`, `rag.lots` | The geometry the chunks are *about*. `rag.chunks.feature_ids` records which map features cite each document, but it holds ids, not shapes |
| `rag.chunk_features`, `rag.search_near`, `rag.search_at_lot` | The joins from geometry to vectors |

The `urban_rag` login role, the `rag` schema, and the grants come from the
dataplatform's own `sql/pgvector_bootstrap.sql` — it lives there because that
is the repo whose code connects as that role. `make db-bootstrap` runs it from
here, where the master credentials are.

Everything in `rag` ends up owned by `urban_rag` whichever order the two
bootstrap steps run in: [`sql/002_spatial.sql`](sql/002_spatial.sql) hands over
ownership if the role exists and emits a `NOTICE` if it does not.

---

## First-time setup

```bash
export AWS_PROFILE=charles_gauvin_east_1
make db-deps           # boto3 + psycopg for scripts/db.py
```

### 1. State backend (once per account)

```bash
make bootstrap         # local state; creates hbu-tf-state-<account> + hbu-tf-locks
```

### 2. Shared VPC (once)

```bash
make plan-shared
make apply-shared
```

### 3. The database

```bash
make plan  ENV=dev
make apply ENV=dev
make db-wait ENV=dev   # RDS takes ~5–10 min to come up
```

`allow_current_ip = true` means the applying machine's public address is
allowlisted automatically — re-apply after your ISP hands you a new one.

### 4. Bootstrap the database

Order matters only in that `db-bootstrap` creates the role that `db-init` hands
ownership to. Running `db-init` first is fine; re-run it afterwards.

```bash
make db-ca                    # RDS root cert, for sslmode=verify-full
make db-bootstrap ENV=dev     # urban_rag role + grants, password → Secrets Manager
make db-init      ENV=dev     # extensions, rag.features, rag.lots
make db-check     ENV=dev
```

`db-init` will report `003_spatial_search.sql skipped — rag.chunks does not
exist yet`. That is expected: those functions read the dataplatform's table.
Materialize `document_index` over there, then run `make db-init` once more to
create them.

---

## Talking to the database

Nothing below takes a hostname or a password. Terraform publishes the
connection details to SSM under `/hbu-<env>/db/*`, RDS keeps the master
password in Secrets Manager and rotates it, and
[`scripts/db.py`](scripts/db.py) resolves both at call time — so none of these
break when the instance is replaced.

```bash
make db-shell  ENV=dev              # interactive SQL (psql if installed, REPL if not)
make db-check  ENV=dev              # extensions, tables, corpus, index metadata
make db-query  ENV=dev SQL="select * from rag.corpus_status"
make db-url    ENV=dev              # a connection URL for QGIS, DBeaver, psycopg
eval "$(make -s db-env ENV=dev)"    # PG* and URBAN_RAG_PG_* in the shell
eval "$(make -s db-app-env ENV=dev)" # the pipeline's role, password via Secrets Manager
```

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
all — the role still needs `GRANT rds_iam`, which is commented out in the
dataplatform's bootstrap file.

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

---

## Reachability, and the tradeoff

The default is a **public endpoint locked to your IP**, because it is the
posture in which every command above works from a laptop with nothing else set
up. Access is gated entirely by the security group, and `rds.force_ssl = 1`
means the traffic is TLS whatever the client asks for.

It is still a database on the public internet. The private posture is two
variables and a bastion:

```hcl
db_subnet_tier         = "private"   # NOTE: replaces the instance
db_publicly_accessible = false
enable_bastion         = true
```

Then `make db-tunnel ENV=dev` port-forwards 5432 to `localhost:5433` through
Session Manager — no SSH key, no open port, no VPN. Access becomes IAM, revoked
by removing a permission rather than by rotating a key that is already on three
laptops.

Terraform will warn (not fail) if you turn off both the public endpoint and the
bastion, since that leaves nothing outside the VPC able to connect — a fine end
state once ECS is talking to it, and a confusing one before.

---

## Cost

Roughly, in `us-east-1`, for the dev defaults:

| | |
|---|---|
| db.t4g.micro, single-AZ | ~$12/mo |
| 20 GiB gp3 | ~$2/mo |
| Backups (1 day, dev) | pennies |
| Bastion (t4g.nano, off by default) | ~$3/mo |

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
| [`sql/`](sql/) | Extensions, spatial tables, spatial search functions |
| [`scripts/db.py`](scripts/db.py) | The CLI everything above is driven through |
| [`scripts/tunnel.sh`](scripts/tunnel.sh) | Session Manager port forwarding |

### A note on `sql/` ordering

`db.py init` applies every file in `sql/` in name order, and a file may declare
a dependency it cannot be parsed without:

```sql
-- requires: rag.chunks
```

`db.py` checks that relation with `to_regclass` and skips the file with a note
if it is missing. A SQL-language function body is parsed at `CREATE` time, so
`003_spatial_search.sql` genuinely cannot be created before the dataplatform's
table exists — and a hard error on the first run of a new database would be
noise rather than information.
