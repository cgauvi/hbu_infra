# ---------------------------------------------------------------------------
# Who is allowed to reach port 5432
#
# Three sources, all optional and all additive:
#
#   1. the public IP of whoever ran `terraform apply` (var.allow_current_ip)
#   2. any extra ranges named in var.allowed_cidr_blocks
#   3. the bastion's security group, when var.enable_bastion is on
#
# With none of them set the database is created with no ingress at all, which
# is a working — if useless — configuration rather than an error.
# ---------------------------------------------------------------------------

# checkip returns the caller's address as bare text plus a trailing newline.
data "http" "current_ip" {
  count = var.allow_current_ip ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  current_ip_cidr = var.allow_current_ip ? ["${chomp(data.http.current_ip[0].response_body)}/32"] : []
  db_cidr_blocks  = distinct(concat(local.current_ip_cidr, var.allowed_cidr_blocks))
}

resource "aws_security_group" "db" {
  name        = "${local.prefix}-db-sg"
  description = "Postgres access for ${local.prefix}"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = { Name = "${local.prefix}-db-sg" }

  # A security group cannot be deleted while an instance still references it,
  # so replacements have to create the new one first.
  lifecycle {
    create_before_destroy = true
  }
}

# Rules are separate resources rather than inline blocks: an inline `ingress`
# list is authoritative and would revert any rule added out of band, which is
# exactly what you want here, but separate rules let a single CIDR change
# without churning the whole group.
resource "aws_vpc_security_group_ingress_rule" "db_from_cidr" {
  for_each = toset(local.db_cidr_blocks)

  security_group_id = aws_security_group.db.id
  description       = "Postgres from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_bastion" {
  count = var.enable_bastion ? 1 : 0

  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from the SSM bastion"
  referenced_security_group_id = aws_security_group.bastion[0].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

# RDS never initiates outbound connections, but a security group with no
# egress rule at all blocks nothing meaningful and confuses readers, so state
# the intent explicitly.
resource "aws_vpc_security_group_egress_rule" "db_all" {
  security_group_id = aws_security_group.db.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
