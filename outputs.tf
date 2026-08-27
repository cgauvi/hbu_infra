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

# ---------------------------------------------------------------------------
# The web application
#
# Written as `one(resource[*].attr)` rather than as the
# `var.enable_bastion ? aws_instance.bastion[0].id : null` form used above.
# Both work; the splat form does not depend on the guard and the index staying
# in agreement, which is the failure mode when a variable is later renamed or
# a resource picks up a second condition. `one()` of an empty list is null,
# which is what all of these mean when the app is switched off.
# ---------------------------------------------------------------------------

output "app_url" {
  description = "Where the front end is served. The ALB's own DNS name until app_certificate_arn puts a domain in front of it."
  value = one([
    for lb in aws_lb.app :
    format("%s://%s", var.app_certificate_arn == "" ? "http" : "https", lb.dns_name)
  ])
}

output "app_cluster" {
  description = "ECS cluster name — what `aws ecs` calls take as --cluster"
  value       = one(aws_ecs_cluster.main[*].name)
}

output "app_service" {
  description = "ECS service name — what `aws ecs update-service` takes as --service"
  value       = one(aws_ecs_service.app[*].name)
}

output "app_image" {
  description = "Image the service is currently configured to run"
  value       = var.enable_app ? local.app_image : null
}

output "app_log_group" {
  description = "CloudWatch log group carrying the container's stdout"
  value       = one(aws_cloudwatch_log_group.app[*].name)
}

output "app_password_secret_arn" {
  description = "Secrets Manager ARN holding the shared access password. Terraform creates it with a placeholder and then ignores the value; `make app-password` sets the real one."
  value       = one(aws_secretsmanager_secret.app_password[*].arn)
}

output "app_hf_token_secret_arn" {
  description = "Secrets Manager ARN holding the HuggingFace Inference API token. Set with `make app-hf-token`."
  value       = one(aws_secretsmanager_secret.hf_token[*].arn)
}

output "app_mapbox_token_secret_arn" {
  description = "Secrets Manager ARN holding the Mapbox public token for the basemap. Optional — set with `make app-mapbox-token`; left at the placeholder the map uses OpenStreetMap."
  value       = one(aws_secretsmanager_secret.mapbox_token[*].arn)
}

# ---------------------------------------------------------------------------
# Pointing a domain at the load balancer
#
# An ALB has no fixed address — AWS moves it between IPs as it scales — so the
# record has to name the load balancer, never an A record holding an IP.
#
# Two ways to do it, depending on where the zone lives:
#
#   Outside Route 53 (Cloudflare, Namecheap, a registrar's own DNS)
#     CNAME  app.example.com -> app_dns_target
#     A CNAME cannot sit at the zone apex, so this has to be a subdomain.
#
#   In Route 53
#     An alias A record, which is free, resolves at the apex, and needs both
#     app_dns_target and app_dns_zone_id (the ALB's hosted zone, not yours).
#
# Either way the name has to be one the certificate covers, or the browser
# warns — the certificate does not cover the ALB's own elb.amazonaws.com name.
# ---------------------------------------------------------------------------

output "app_dns_target" {
  description = "The ALB's DNS name — the value a CNAME points at, or the alias target in Route 53. Bare hostname, no scheme."
  value       = one(aws_lb.app[*].dns_name)
}

output "app_dns_zone_id" {
  description = "Hosted zone of the ALB itself — the alias_target zone_id for a Route 53 alias record. Not the zone id of your own domain."
  value       = one(aws_lb.app[*].zone_id)
}

output "app_dns_record" {
  description = "The record to create, spelled out. Replace app.example.com with a name the certificate covers."
  value = one([
    for lb in aws_lb.app : <<-EOT
      CNAME  app.example.com  ->  ${lb.dns_name}

      Or, in Route 53, an alias A record on app.example.com with:
        alias_target.name    = ${lb.dns_name}
        alias_target.zone_id = ${lb.zone_id}

      Certificate on the listener: ${var.app_certificate_arn == "" ? "none — HTTP only" : var.app_certificate_arn}
    EOT
  ])
}
