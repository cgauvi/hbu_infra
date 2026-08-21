environment = "dev"

# Reachable from a laptop, locked to the applying machine's public IP.
db_subnet_tier         = "public"
db_publicly_accessible = true
allow_current_ip       = true

# Sizing is an HNSW question, not a storage one: the index has to fit in
# memory to be fast, at roughly rows x dimension x 4 bytes plus the graph.
# 1024-wide bge-m3 vectors are ~4 KB each, so the current VSMPE corpus (~500
# chunks, ~2 MB) fits a micro with room to spare. Past ~100k chunks that is
# ~400 MB of vectors alone and this wants a db.t4g.medium.
db_instance_class    = "db.t4g.micro"
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

enable_bastion = false
