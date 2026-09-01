environment = "dev"

# The private posture: the instance sits in subnets with no route off the VPC
# and has no public endpoint, so the only way in is the bastion's security
# group. Nothing is pinned to a home IP any more, which is the point -- a
# changing address no longer means re-applying the security group.
db_subnet_tier         = "private"
db_publicly_accessible = false
allow_current_ip       = false

# Sizing is normally an HNSW question, not a storage one: the index has to
# fit in memory to be fast, at roughly rows x dimension x 4 bytes plus the
# graph. 1024-wide bge-m3 vectors are ~4 KB each, so the current VSMPE corpus
# (~500 chunks, ~2 MB) fits a micro with room to spare. Past ~100k chunks
# that is ~400 MB of vectors alone and this wants a db.t4g.medium.
#
# It is a different question for the HBU spatial assets, which is why this is
# currently db.m6g.large rather than the micro the corpus alone would need.
# `silver.lot_buildable_setbacks` classifies every boundary segment of every
# lot in a borough inside one server-side `CREATE TEMP TABLE AS`, and on a
# micro (1 GB RAM, burstable) that statement cannot finish within
# `URBAN_RAG_PG_STATEMENT_TIMEOUT_SECONDS` at all — it was still running past
# 30 minutes on a full VSMPE partition and had to be killed. On m6g.large it
# completes in under an hour end to end. Resized 2026-08-31 for that run; move
# back to db.t4g.micro when the pipeline is not actively being materialized —
# it costs roughly 10x as much per hour idle.
db_instance_class    = "db.m6g.large"
db_allocated_storage = 20

# Dev is rebuildable from the dataplatform's parquet, so keep one day of
# backups against a bad migration and nothing more.
db_backup_retention_days = 1
db_deletion_protection   = false
db_skip_final_snapshot   = true

# Off by default: a stopped instance makes `make db-*` hang on connect rather
# than fail, which is a confusing first experience. Turn it on once the shape
# of the work is familiar.
enable_scheduled_shutdown = false

# Required by the above: with no public endpoint this is the only path from a
# laptop. `make db-tunnel` port-forwards through it over Session Manager, and
# every db-* target then runs against localhost.
enable_bastion = true

# ---------------------------------------------------------------------------
# The web application
#
# Ordering matters on a first run: the ECR repository comes from the shared
# stack and the service cannot stabilise against a tag that is not in it yet.
#
#   make apply-shared            # creates hbu-rag-map in ECR
#   make app-push   ENV=dev      # builds and pushes :latest
#   make app-password ENV=dev    # the shared password, before anyone can log in
#   make app-hf-token ENV=dev    # the Inference API token
#   make plan apply ENV=dev      # with enable_app = true below
# ---------------------------------------------------------------------------
enable_app    = true
app_image_tag = "latest"

# One task. Session state and the map cache both live in the task's memory, so
# a second one buys availability, not capacity, and doubles the Fargate bill.
app_desired_count = 1
app_cpu           = "512"
app_memory        = "1024"

# Public, gated by the shared password the app asks for. With the certificate
# set below, 80 redirects to 443 and that password crosses the wire encrypted.
# The remaining caveat is that it is one password for everyone, so revoking it
# means changing it for everyone.
#
# The certificate has to live in the same region as the ALB (us-east-1 here)
# and cover whatever name is pointed at the load balancer. Reaching the ALB by
# its own *.elb.amazonaws.com name will still warn, because no public CA
# issues for that domain -- see the app_dns_target output for the record to
# create.
app_ingress_cidr_blocks = ["0.0.0.0/0"]
app_certificate_arn     = "arn:aws:acm:us-east-1:038083667790:certificate/5f2413a2-1122-4769-abb2-45249768c58d"

# "dev" would put the log pane in the sidebar of a page anyone with the
# password can open. Keep the logs in CloudWatch instead.
app_env_mode = "prod"

# `make app-shell` opens a shell in the running task over SSM — the fastest way
# to find out why a connection the logs do not explain is failing.
app_enable_execute_command = true
