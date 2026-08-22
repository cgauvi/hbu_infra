variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the project (used for resource naming)"
  type        = string
  default     = "hbu"
}

variable "environment" {
  description = "Deployment environment (e.g. dev, prod)"
  type        = string
  default     = "dev"
}

# ---------------------------------------------------------------------------
# Database — engine and sizing
# ---------------------------------------------------------------------------

variable "db_engine_version" {
  description = "PostgreSQL major version. A bare major ('16') tracks the latest minor RDS offers, which is what auto_minor_version_upgrade applies anyway. PostGIS and pgvector are both available on 15 and 16."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "RDS instance class. db.t4g.micro is the cheapest Graviton option and holds a corpus of this size comfortably; move to db.t4g.small if HNSW builds start swapping."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Initial storage (GiB). gp3's floor is 20."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Ceiling (GiB) for RDS storage autoscaling. Set equal to db_allocated_storage to disable growth."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Name of the initial database created on the instance"
  type        = string
  default     = "urban_rag"
}

variable "db_username" {
  description = "Master username. The password is generated and rotated by RDS into Secrets Manager — it is never written to Terraform state."
  type        = string
  default     = "hbu_admin"
}

variable "db_multi_az" {
  description = "Run a standby in a second AZ. Doubles the instance cost; off by default."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Days of automated backups to keep. 0 disables backups entirely (and with them, point-in-time recovery)."
  type        = number
  default     = 7
}

variable "db_deletion_protection" {
  description = "Block `terraform destroy` from dropping the instance. Leave on for anything holding a corpus you do not want to re-embed."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Convenient in dev, dangerous in prod."
  type        = bool
  default     = true
}

variable "db_apply_immediately" {
  description = "Apply instance modifications at once instead of in the next maintenance window. Some changes cause a brief outage."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Database — reachability
# ---------------------------------------------------------------------------

variable "db_subnet_tier" {
  description = "Which shared DB subnet group to place the instance in: 'public' (required for a public endpoint) or 'private' (in-VPC only, reachable through the bastion). Changing this REPLACES the instance."
  type        = string
  default     = "public"

  validation {
    condition     = contains(["public", "private"], var.db_subnet_tier)
    error_message = "db_subnet_tier must be either 'public' or 'private'."
  }
}

variable "db_publicly_accessible" {
  description = "Give the instance a public endpoint. Access is still gated entirely by the security group — nothing reaches port 5432 unless an ingress rule below allows it — and rds.force_ssl makes every connection TLS. Requires db_subnet_tier = 'public'."
  type        = bool
  default     = true
}

variable "allow_current_ip" {
  description = "Allow the public IP of the machine running `terraform apply` to reach the database. Re-apply after your address changes to refresh the rule."
  type        = bool
  default     = true
}

variable "allowed_cidr_blocks" {
  description = "Extra CIDR blocks allowed to reach port 5432 (an office range, a VPN egress address). Added on top of allow_current_ip."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Bastion — optional SSM jump host for a private database
# ---------------------------------------------------------------------------

variable "enable_bastion" {
  description = "Create a t4g.nano host that Session Manager can port-forward through, so `make db-tunnel` reaches a database with no public endpoint. It has no SSH key and no inbound rules; access is IAM, not a keypair."
  type        = bool
  default     = false
}

variable "bastion_instance_type" {
  description = "Instance type for the SSM bastion. It forwards TCP and runs nothing else."
  type        = string
  default     = "t4g.nano"
}

# ---------------------------------------------------------------------------
# Scheduled stop/start (cost saving)
# ---------------------------------------------------------------------------

variable "enable_scheduled_shutdown" {
  description = "Stop the instance overnight and start it again in the morning, via EventBridge Scheduler calling the RDS API directly. Roughly halves the instance-hour bill. Storage is billed while stopped."
  type        = bool
  default     = false
}

variable "stop_cron" {
  description = "Schedule expression for stopping the instance. Interpreted in var.schedule_timezone, so it does not drift across daylight saving."
  type        = string
  default     = "cron(0 22 * * ? *)"
}

variable "start_cron" {
  description = "Schedule expression for starting the instance back up."
  type        = string
  default     = "cron(0 8 * * ? *)"
}

variable "schedule_timezone" {
  description = "IANA timezone the stop/start crons are evaluated in."
  type        = string
  default     = "America/Montreal"
}

# ---------------------------------------------------------------------------
# Application role
# ---------------------------------------------------------------------------

variable "app_db_username" {
  description = "Login role the pipeline and the query side connect as — created by sql/000_roles.sql, which expects this exact name. It owns the `rag` schema and nothing else; the master user is only for bootstrap and migrations."
  type        = string
  default     = "urban_rag"
}
