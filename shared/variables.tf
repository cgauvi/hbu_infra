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

variable "vpc_cidr" {
  description = "CIDR block for the shared VPC. Every environment's RDS instance and (later) ECS tasks run in subnets of this VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across. RDS DB subnet groups require at least 2."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2 — an RDS DB subnet group requires subnets in two or more AZs."
  }
}
