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

variable "current_ip" {
  description = "The address allow_current_ip refers to, as a bare IPv4 address with no mask. The Makefile fills this in from https://checkip.amazonaws.com, so it belongs on the command line rather than in a tfvars file, where it would go stale. Ignored when allow_current_ip is false."
  type        = string
  default     = ""

  # An unreachable checkip, or a proxy answering with an HTML error page,
  # otherwise shows up much later as a malformed CIDR from the AWS API.
  validation {
    condition     = var.current_ip == "" || can(cidrhost("${var.current_ip}/32", 0))
    error_message = "current_ip must be a bare IPv4 address with no mask, e.g. 203.0.113.4."
  }
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
  description = "Login role the pipeline and the query side connect as — created by sql/000_roles.sql, which expects this exact name. It owns the `rag` corpus/spatial schema and the `dagster` metadata schema; the master user is only for bootstrap and migrations."
  type        = string
  default     = "urban_rag"
}

# ---------------------------------------------------------------------------
# The web application — Fargate behind an ALB
#
# Off by default because of a hard ordering constraint: the service points at
# an image tag, and a service whose tag does not exist in ECR yet cannot
# stabilise. The sequence is `make apply-shared` (creates the repository),
# `make app-push` (puts an image in it), then flip this on.
# ---------------------------------------------------------------------------

variable "enable_app" {
  description = "Create the ALB, the ECS cluster, and the Fargate service running the Streamlit front end. Requires an image already pushed to the shared ECR repository."
  type        = bool
  default     = false
}

variable "app_image_tag" {
  description = "Tag in the shared ECR repository to run. 'latest' pairs with `make app-deploy`, which forces a new deployment when the tag moves; pin an immutable tag or a digest for anything you want to stay put."
  type        = string
  default     = "latest"
}

variable "app_port" {
  description = "Port Streamlit listens on inside the container. Matches the Dockerfile's EXPOSE and its CMD."
  type        = number
  default     = 8501
}

variable "app_tile_port" {
  description = "Port the map's vector tile server listens on inside the container. hbu_rag_map runs it in the same process as Streamlit, on a second socket, because Streamlit serves no routes of its own and Leaflet has to fetch tiles over HTTP. The ALB routes /tiles/* here; matches HBU_TILE_PORT and the Dockerfile's second EXPOSE."
  type        = number
  default     = 8502
}

variable "app_tile_path_pattern" {
  description = "The listener rule that separates tile traffic from the app's. Everything else falls through to the Streamlit target group, websocket included."
  type        = string
  default     = "/tiles/*"
}

variable "app_desired_count" {
  description = "How many tasks to run. One is enough for this workload and is what the cost model assumes; more than one is fine because the ALB is sticky, but each task holds its own session state and its own cache."
  type        = number
  default     = 1
}

variable "app_cpu" {
  description = "Fargate task CPU units (1024 = 1 vCPU). The app is IO-bound on Postgres and the Inference API, so this is about cold-start speed more than throughput."
  type        = string
  default     = "512"
}

variable "app_memory" {
  description = "Fargate task memory in MiB. Must be a legal pairing with app_cpu — 512 CPU allows 1024 through 4096 in 1024 steps. Folium builds whole map documents in memory, so 1024 is the sensible floor."
  type        = string
  default     = "1024"
}

variable "app_cpu_architecture" {
  description = "X86_64 or ARM64. ARM64 is roughly 20% cheaper per task-hour but the image has to be built for it — `docker buildx build --platform linux/arm64` — which a stock Windows or Intel Mac build is not."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.app_cpu_architecture)
    error_message = "app_cpu_architecture must be either 'X86_64' or 'ARM64'."
  }
}

variable "app_env_mode" {
  description = "APP_ENV inside the container. 'dev' shows the log pane in the sidebar; 'prod' hides it. A shared password is not much of a barrier in front of a log pane, so prefer 'prod' on anything public."
  type        = string
  default     = "prod"
}

variable "app_log_level" {
  description = "LOG_LEVEL inside the container."
  type        = string
  default     = "INFO"
}

variable "app_log_retention_days" {
  description = "Days to keep the task's CloudWatch logs."
  type        = number
  default     = 14
}

# ---------------------------------------------------------------------------
# The application — reachability
# ---------------------------------------------------------------------------

variable "app_ingress_cidr_blocks" {
  description = "Who can reach the load balancer. The default is the whole internet, which is only defensible because the app asks for a shared password before it renders anything — see app_certificate_arn for the other half of that."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "app_certificate_arn" {
  description = "ACM certificate for an HTTPS listener. Empty means HTTP only, and the shared password is then sent in the clear — acceptable behind a narrow app_ingress_cidr_blocks, not acceptable open to the internet. Setting this adds a 443 listener and turns 80 into a redirect, in place, without replacing the load balancer or changing its DNS name."
  type        = string
  default     = ""
}

variable "app_idle_timeout" {
  description = "Seconds the ALB holds an idle connection. Streamlit's websocket goes quiet while someone reads an answer, and the ALB default of 60 closes it mid-session."
  type        = number
  default     = 300
}

variable "app_session_duration" {
  description = "Seconds the stickiness cookie lives. Session state is in the task's memory, so this is how long a browser keeps finding the task that holds its conversation."
  type        = number
  default     = 86400
}

variable "app_deletion_protection" {
  description = "Block `terraform destroy` from deleting the load balancer. Its DNS name is what anyone with the link has bookmarked, and a replacement gets a new one."
  type        = bool
  default     = false
}

variable "app_wait_for_steady_state" {
  description = "Make `terraform apply` wait for the deployment to stabilise, so a broken image fails the apply instead of failing silently in a browser. Costs a few minutes on every apply that touches the service."
  type        = bool
  default     = true
}

variable "app_enable_execute_command" {
  description = "Allow `make app-shell` to open a shell inside a running task over SSM. Useful for diagnosing a connection the logs do not explain; it is also a shell inside the task role, so leave it off in prod."
  type        = bool
  default     = true
}

variable "app_container_insights" {
  description = "Per-task CPU and memory metrics in CloudWatch. Billed as custom metrics, which at one task is small but not nothing."
  type        = bool
  default     = false
}
