# Bootstrap — creates the S3 bucket and DynamoDB table that every other
# Terraform workspace in this project uses as its remote state backend.
#
# This module uses LOCAL state intentionally: it only needs to be applied once
# with local credentials, and it must never be stored in the backend it is
# itself creating.
#
# Usage (one-time):
#   cd bootstrap
#   terraform init
#   terraform apply
#
# There is no GitHub OIDC role here yet — deploys are manual. When CI is added,
# the provider + deploy role belong in this file, next to the state bucket,
# because both need admin credentials and both are per-account, not per-env.

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region where the state bucket and lock table will be created"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name — used as a prefix for resource names"
  type        = string
  default     = "hbu"
}

# ---------------------------------------------------------------------------
# Account ID — used to ensure a globally unique S3 bucket name
# ---------------------------------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.project_name}-tf-state-${data.aws_caller_identity.current.account_id}"
  table_name  = "${var.project_name}-tf-locks"
}

# ---------------------------------------------------------------------------
# S3 Bucket — Terraform state storage
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tf_state" {
  bucket = local.bucket_name

  # Prevent accidental deletion of state
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# DynamoDB Table — state lock to prevent concurrent applies
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "tf_locks" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "state_bucket_name" {
  description = "S3 bucket name for Terraform state — use as 'bucket' in backend config"
  value       = aws_s3_bucket.tf_state.id
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for state locking — use as 'dynamodb_table' in backend config"
  value       = aws_dynamodb_table.tf_locks.name
}

output "aws_region" {
  description = "Region where the backend resources were created"
  value       = var.aws_region
}
