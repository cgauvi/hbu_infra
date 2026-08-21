terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial backend config — bucket, key, and dynamodb_table are supplied at
  # init time via -backend-config CLI flags (see the Makefile). State key is
  # hbu/shared/terraform.tfstate. Region is fixed here so a plain
  # `terraform init` does not fail with "Missing region".
  backend "s3" {
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      Scope     = "shared"
      ManagedBy = "terraform"
    }
  }
}
