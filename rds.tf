locals {
  # A DB parameter group family is keyed to the major version only, so a
  # db_engine_version of "16" and "16.4" both belong to "postgres16".
  db_family = "postgres${split(".", var.db_engine_version)[0]}"

  db_subnet_group_name = data.terraform_remote_state.shared.outputs.db_subnet_group_names[var.db_subnet_tier]
}

# ---------------------------------------------------------------------------
# Parameter group
#
# Deliberately thin. PostGIS and pgvector are both plain extensions — neither
# needs preloading — and RDS already ships postgres16 with
# shared_preload_libraries = "pg_stat_statements,pg_tle". Restating that here
# would only risk dropping pg_tle from the list and force a reboot to apply a
# value the engine already has.
#
# Index-build memory is likewise absent on purpose: maintenance_work_mem
# matters only while an HNSW index is being built, so scripts/db.py raises it
# per session rather than holding it open for every connection on a 1 GiB
# instance.
# ---------------------------------------------------------------------------

resource "aws_db_parameter_group" "main" {
  name_prefix = "${local.prefix}-pg-"
  family      = local.db_family
  description = "Postgres parameters for ${local.prefix}"

  # Reject non-TLS connections. RDS defaults this to 1 already; it is restated
  # so the guarantee survives a change of engine default. Dynamic, so it takes
  # effect without a reboot.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "immediate"
  }

  # Log anything slower than 2s. A vector search that quietly fell back to a
  # sequential scan — because the HNSW index was not built, or the query used
  # a different operator than the index's opclass — shows up here first.
  parameter {
    name         = "log_min_duration_statement"
    value        = "2000"
    apply_method = "immediate"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Log group
#
# RDS creates this itself on first log export. Declaring it first — and making
# the instance depend on it — means it exists with a retention policy attached
# instead of defaulting to "never expire".
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/instance/${local.prefix}/postgresql"
  retention_in_days = 7
}

# ---------------------------------------------------------------------------
# Subnet tier changes are replacements, not modifications
#
# ModifyDBInstance accepts a new DB subnet group only when it moves the
# instance to a *different* VPC; inside one VPC it answers
# InvalidVPCNetworkStateFault. The provider does not model that, so changing
# db_subnet_tier plans as a clean in-place update and then fails half way
# through an apply. Keying a trigger to the tier states the truth up front:
# public -> private is a new instance, planned as one and visible before
# anyone types yes.
# ---------------------------------------------------------------------------

resource "terraform_data" "db_subnet_tier" {
  input = var.db_subnet_tier
}

# ---------------------------------------------------------------------------
# The instance
# ---------------------------------------------------------------------------

resource "aws_db_instance" "main" {
  identifier     = local.prefix
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  db_name  = var.db_name
  username = var.db_username

  # RDS generates the master password, stores it in Secrets Manager, and owns
  # rotation. Terraform never sees it, so it cannot leak through the state
  # file — which is the usual way a database password ends up in an S3 bucket.
  manage_master_user_password = true

  # gp3 has a fixed baseline of 3000 IOPS at any size, so a 20 GiB volume is
  # not the 60-IOPS trickle the same size would be on gp2.
  storage_type          = "gp3"
  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_encrypted     = true

  db_subnet_group_name   = local.db_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = var.db_publicly_accessible
  port                   = 5432

  parameter_group_name = aws_db_parameter_group.main.name

  multi_az                   = var.db_multi_az
  auto_minor_version_upgrade = true
  apply_immediately          = var.db_apply_immediately

  # Lets a role authenticate with a 15-minute signed token instead of a stored
  # password — what URBAN_RAG_PG_IAM_AUTH=1 expects on the pipeline side. It
  # costs nothing to leave on, and the database role still has to be granted
  # rds_iam before any token is accepted.
  iam_database_authentication_enabled = true

  backup_retention_period = var.db_backup_retention_days
  backup_window           = "07:00-08:00" # UTC — ahead of the 08:00 local start
  maintenance_window      = "Mon:08:30-Mon:09:30"

  copy_tags_to_snapshot     = true
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = var.db_skip_final_snapshot
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.prefix}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  depends_on = [aws_cloudwatch_log_group.postgresql]

  lifecycle {
    replace_triggered_by = [terraform_data.db_subnet_tier]

    ignore_changes = [
      # A bare major version ("16") is normalised by RDS to whatever minor it
      # actually launched, and auto_minor_version_upgrade moves it again.
      # Without this, every plan after a minor upgrade proposes a downgrade.
      engine_version,
      # Recomputed from timestamp() on every plan; only read on destroy.
      final_snapshot_identifier,
    ]
  }
}

# A precondition rather than a variable validation, because it spans two
# variables: the RDS API accepts a public endpoint in a subnet with no internet
# gateway and the endpoint then simply never resolves.
resource "terraform_data" "reachability_check" {
  lifecycle {
    precondition {
      condition     = !var.db_publicly_accessible || var.db_subnet_tier == "public"
      error_message = "db_publicly_accessible = true requires db_subnet_tier = \"public\" — a public endpoint in a subnet with no internet gateway route is unreachable."
    }
  }
}

# A warning, not an error: a database reachable only from inside the VPC is a
# perfectly good end state once ECS is talking to it. It is just not one you
# want to arrive at by accident while there is nothing else in the VPC yet.
check "reachable_from_somewhere" {
  assert {
    condition     = var.db_publicly_accessible || var.enable_bastion
    error_message = "Nothing outside the VPC can reach this database: it has no public endpoint and no bastion. Set enable_bastion = true to keep `make db-*` working."
  }
}
