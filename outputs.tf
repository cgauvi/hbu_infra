output "db_endpoint" {
  description = "Host:port of the database"
  value       = aws_db_instance.main.endpoint
}

output "db_host" {
  description = "Hostname of the database"
  value       = aws_db_instance.main.address
}

output "db_name" {
  description = "Name of the initial database"
  value       = aws_db_instance.main.db_name
}

output "db_username" {
  description = "Master username"
  value       = aws_db_instance.main.username
}

output "db_instance_id" {
  description = "RDS instance identifier — pass to `aws rds start-db-instance` after a scheduled stop"
  value       = aws_db_instance.main.identifier
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the RDS-managed master password"
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "db_security_group_id" {
  description = "Security group guarding port 5432 — reference it from an ECS task SG to grant in-VPC access"
  value       = aws_security_group.db.id
}

output "db_allowed_cidr_blocks" {
  description = "CIDR blocks currently allowed to reach the database from outside the VPC"
  value       = local.db_cidr_blocks
}

output "db_access_policy_arn" {
  description = "IAM policy granting read of the connection parameters and the master secret — attach to any role that talks to this database"
  value       = aws_iam_policy.db_access.arn
}

output "ssm_parameter_prefix" {
  description = "SSM namespace holding the connection contract that scripts/db.py reads"
  value       = "/${local.prefix}"
}

output "bastion_instance_id" {
  description = "Instance ID of the SSM bastion, when enabled — the tunnel target"
  value       = var.enable_bastion ? aws_instance.bastion[0].id : null
}

output "psql_command" {
  description = "Connect with psql, resolving the password from Secrets Manager at call time"
  value       = <<-EOT
    PGPASSWORD=$(aws secretsmanager get-secret-value \
      --secret-id ${aws_db_instance.main.master_user_secret[0].secret_arn} \
      --region ${var.aws_region} --query SecretString --output text | jq -r .password) \
    psql "host=${aws_db_instance.main.address} port=${aws_db_instance.main.port} dbname=${aws_db_instance.main.db_name} user=${aws_db_instance.main.username} sslmode=require"
  EOT
}

output "app_role_secret_arn" {
  description = "Secrets Manager ARN for the pipeline's `urban_rag` role — URBAN_RAG_PG_SECRET_ID. Populated by `make db-bootstrap`, not by Terraform."
  value       = aws_secretsmanager_secret.app_role.arn
}

output "app_env" {
  description = "Environment the dataplatform's PgSettings.from_env reads. No password: the pipeline resolves it from the secret itself."
  value = {
    URBAN_RAG_PG_HOST      = aws_db_instance.main.address
    URBAN_RAG_PG_PORT      = tostring(aws_db_instance.main.port)
    URBAN_RAG_PG_DATABASE  = aws_db_instance.main.db_name
    URBAN_RAG_PG_USER      = var.app_db_username
    URBAN_RAG_PG_SECRET_ID = aws_secretsmanager_secret.app_role.arn
    URBAN_RAG_PG_REGION    = var.aws_region
    URBAN_RAG_PG_SSLMODE   = "verify-full"
  }
}

output "next_steps" {
  description = "What to run once the instance is available"
  value       = <<-EOT
    make db-ca                             # RDS root cert, for sslmode=verify-full
    make db-bootstrap ENV=${var.environment}   # the ${var.app_db_username} role + grants
    make db-init      ENV=${var.environment}   # extensions, rag/dagster schemas, spatial tables
    make db-check     ENV=${var.environment}   # confirm what is installed

    Then, in hbu_dataplatform, materialize document_index to create and fill
    rag.chunks — and re-run `make db-init` to add the spatial search functions
    that read it.
  EOT
}
