environment = "prod"

db_subnet_tier         = "public"
db_publicly_accessible = true
allow_current_ip       = true

# 4 GB, so a full-borough HNSW index stays resident rather than spilling to
# disk on every search. See the sizing note in dev.tfvars.
db_instance_class        = "db.t4g.medium"
db_allocated_storage     = 50
db_max_allocated_storage = 200

db_backup_retention_days = 7
db_deletion_protection   = true
db_skip_final_snapshot   = false
db_multi_az              = false

enable_scheduled_shutdown = false
enable_bastion            = false

# The private posture, once ECS is talking to the database and a laptop no
# longer needs to. dev already runs it:
#   db_subnet_tier         = "private"
#   db_publicly_accessible = false
#   allow_current_ip       = false
#   enable_bastion         = true
#
# Changing the tier REPLACES the instance -- RDS refuses to move one between
# subnet groups inside a single VPC -- and the plan will claim otherwise unless
# you pass -replace=aws_db_instance.main. On prod that means a snapshot restore
# rather than the empty rebuild dev got. See "Reachability" in the README.
