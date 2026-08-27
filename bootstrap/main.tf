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

# ---------------------------------------------------------------------------
# GitHub Actions OIDC Federation
#
# Creates the deploy role and policy hbu_rag_map's GitHub Actions workflows
# use to authenticate with AWS via short-lived tokens. The OIDC provider
# itself is NOT created here — one already exists in this account (created by
# ebird-llm's bootstrap module, arn:aws:iam::038083667790:oidc-provider/
# token.actions.githubusercontent.com), and an account may only register a
# given provider URL once. It is looked up as a data source instead.
#
# Run once locally with admin credentials:
#   cd bootstrap
#   terraform apply
#
# After apply, copy the output ARN into GitHub:
#   cgauvi/hbu_rag_map repo → Settings → Secrets → Actions → AWS_DEPLOY_ROLE_ARN
# ---------------------------------------------------------------------------

variable "github_repo" {
  description = "GitHub repository in 'owner/repo' format that is allowed to assume the deploy role"
  type        = string
  default     = "cgauvi/hbu_rag_map"
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_oidc_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # Covers the deploy workflow's own triggers: pushes to the deployment
      # branches (via workflow_run, which still presents the branch ref) and
      # workflow_dispatch runs, both of which authenticate with the ref of
      # whichever branch they ran from. No GitHub Environment is used here,
      # so no environment:<name> sub is needed.
      values = [
        "repo:${var.github_repo}:ref:refs/heads/master",
        "repo:${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_repo}:ref:refs/heads/develop",
      ]
    }
  }
}

resource "aws_iam_role" "hbu_github_deploy" {
  name               = "hbu-github-deploy"
  description        = "GitHub Actions OIDC deploy role for cgauvi/hbu_rag_map (build+push ECR, roll ECS service)"
  assume_role_policy = data.aws_iam_policy_document.github_oidc_assume.json
}

# Scoped to exactly what hbu_rag_map/.github/workflows/deploy.yml does: push
# the runtime image to the one shared ECR repository, register a new task
# definition revision, and roll the ECS service. It does not grant anything
# hbu_infra's own Terraform applies need (VPC, RDS, ALB, IAM role creation,
# …) — those stay manual, run locally, matching the rest of this account's
# posture.
data "aws_iam_policy_document" "hbu_github_deploy" {
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ECRPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [
      "arn:aws:ecr:*:${data.aws_caller_identity.current.account_id}:repository/hbu-rag-map",
    ]
  }

  # DescribeTaskDefinition and RegisterTaskDefinition do not support
  # resource-level restriction (AWS requires "*" for both), so the trust
  # policy above — scoped to this one repo's branches — is what actually
  # limits blast radius, not this resources list.
  statement {
    sid    = "ECSTaskDefinition"
    effect = "Allow"
    actions = [
      "ecs:DescribeTaskDefinition",
      "ecs:RegisterTaskDefinition",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ECSService"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:UpdateService",
    ]
    resources = [
      "arn:aws:ecs:*:${data.aws_caller_identity.current.account_id}:service/hbu-*/hbu-*-rag-map",
    ]
  }

  # register-task-definition needs to hand the task its execution and task
  # roles — both named hbu-<env>-app-*, see ecs.tf in the per-env stack.
  statement {
    sid     = "PassAppRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/hbu-*-app-execution",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/hbu-*-app-task",
    ]
  }

  # The "Print app URL" step. DescribeLoadBalancers has no resource-level
  # permission support either.
  statement {
    sid       = "ELBDescribe"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:DescribeLoadBalancers"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "hbu_github_deploy" {
  name   = "hbu-github-deploy"
  role   = aws_iam_role.hbu_github_deploy.id
  policy = data.aws_iam_policy_document.hbu_github_deploy.json
}

output "github_deploy_role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions via OIDC — copy into GitHub secret AWS_DEPLOY_ROLE_ARN on cgauvi/hbu_rag_map"
  value       = aws_iam_role.hbu_github_deploy.arn
}
