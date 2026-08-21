terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Used only to look up the public IP of the machine running `apply`, so the
    # database security group can allow it without hard-coding an address that
    # goes stale every time the ISP hands out a new lease.
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # Partial backend config — bucket, key, and dynamodb_table are supplied at
  # init time via -backend-config CLI flags (see the Makefile). State key is
  # hbu/<env>/terraform.tfstate.
  backend "s3" {
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
