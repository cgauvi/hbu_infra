output "vpc_id" {
  description = "ID of the shared VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the shared VPC — per-env stacks use it to scope in-VPC security group rules"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (default route to the internet gateway)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (no route off the VPC)"
  value       = aws_subnet.private[*].id
}

output "db_subnet_group_names" {
  description = "DB subnet group names by tier — the per-env stack selects one with var.db_subnet_tier"
  value = {
    public  = aws_db_subnet_group.public.name
    private = aws_db_subnet_group.private.name
  }
}

output "ecr_repository_url" {
  description = "Registry URL to build and push the application image to — the per-env ECS stack reads it from here"
  value       = aws_ecr_repository.rag_map.repository_url
}

output "ecr_repository_arn" {
  description = "ARN of the application image repository — an ECS execution role needs read on exactly this"
  value       = aws_ecr_repository.rag_map.arn
}

output "ecr_repository_name" {
  description = "Repository name, for `aws ecr` calls that take one rather than a URL"
  value       = aws_ecr_repository.rag_map.name
}
