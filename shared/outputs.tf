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
