# ---------------------------------------------------------------------------
# SSM Parameter Store — how everything else finds the database
#
# One namespace, /<prefix>/db/*, is the single published contract. scripts/db.py
# reads it, and an ECS task definition can inject the same parameters as
# environment variables without either side hard-coding an endpoint that
# changes whenever the instance is replaced.
#
# The password is deliberately absent: RDS owns it in Secrets Manager and
# rotates it. What is published here is the secret's ARN, so a reader with the
# right IAM permission can resolve the current value and one without cannot.
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "db_host" {
  name  = "/${local.prefix}/db/host"
  type  = "String"
  value = aws_db_instance.main.address
}

resource "aws_ssm_parameter" "db_port" {
  name  = "/${local.prefix}/db/port"
  type  = "String"
  value = tostring(aws_db_instance.main.port)
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${local.prefix}/db/name"
  type  = "String"
  value = aws_db_instance.main.db_name
}

resource "aws_ssm_parameter" "db_user" {
  name  = "/${local.prefix}/db/user"
  type  = "String"
  value = aws_db_instance.main.username
}

resource "aws_ssm_parameter" "db_secret_arn" {
  name  = "/${local.prefix}/db/secret_arn"
  type  = "String"
  value = aws_db_instance.main.master_user_secret[0].secret_arn
}

resource "aws_ssm_parameter" "db_instance_id" {
  name        = "/${local.prefix}/db/instance_id"
  description = "RDS instance identifier — used by scripts/db.py to report whether a stopped instance is why a connection is timing out"
  type        = "String"
  value       = aws_db_instance.main.identifier
}

# ---------------------------------------------------------------------------
# The application role
#
# The pipeline does not connect as the master user. It connects as `urban_rag`,
# a login role that owns the `rag` schema and nothing else — created by the
# dataplatform's sql/pgvector_bootstrap.sql, which `make db-bootstrap` runs.
#
# Terraform creates the secret that role's password lives in but never sets it:
# the value is written by `db.py bootstrap --store-password`, which generates
# it. ignore_changes keeps a later apply from reverting it to the placeholder.
#
# The shape is the one PgSettings.secret_id reads, which is also the shape RDS
# writes for a password it manages itself — so the pipeline's resolution path
# is identical whichever role it uses.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "app_role" {
  name        = "${local.prefix}/db/app-role"
  description = "Password for the ${var.app_db_username} role in ${local.prefix}"

  # Long enough to undo a mistake, short enough that a destroyed environment
  # does not block recreating it by the same name for a week.
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "app_role" {
  secret_id = aws_secretsmanager_secret.app_role.id
  secret_string = jsonencode({
    username = var.app_db_username
    password = "PLACEHOLDER"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_ssm_parameter" "db_app_secret_arn" {
  name        = "/${local.prefix}/db/app_secret_arn"
  description = "Secrets Manager ARN holding the ${var.app_db_username} role password — URBAN_RAG_PG_SECRET_ID"
  type        = "String"
  value       = aws_secretsmanager_secret.app_role.arn
}

resource "aws_ssm_parameter" "db_app_user" {
  name  = "/${local.prefix}/db/app_user"
  type  = "String"
  value = var.app_db_username
}

# ---------------------------------------------------------------------------
# IAM — a policy anything talking to this database can attach
#
# Created here rather than inside a future ECS stack because the resources it
# names (the parameter namespace, the RDS-managed secret) are owned here. An
# ECS task role, a Lambda, or a developer role attaches it; none of them need
# to know the ARNs.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "db_access" {
  statement {
    sid       = "ReadConnectionParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${local.prefix}/*"]
  }

  statement {
    sid     = "ReadDatabasePasswords"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      aws_db_instance.main.master_user_secret[0].secret_arn,
      aws_secretsmanager_secret.app_role.arn,
    ]
  }

  # IAM authentication, for the path where nothing stores a password at all.
  # The resource id — not the identifier — is what the ARN is keyed on, and it
  # is stable across a rename. The database role still needs `GRANT rds_iam`.
  statement {
    sid     = "ConnectAsIamUser"
    effect  = "Allow"
    actions = ["rds-db:connect"]
    resources = [
      "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.main.resource_id}/${var.app_db_username}",
    ]
  }

  statement {
    sid       = "DescribeInstance"
    effect    = "Allow"
    actions   = ["rds:DescribeDBInstances"]
    resources = [aws_db_instance.main.arn]
  }
}

resource "aws_iam_policy" "db_access" {
  name        = "${local.prefix}-db-access"
  description = "Resolve the ${local.prefix} database endpoint and master credentials"
  policy      = data.aws_iam_policy_document.db_access.json
}
