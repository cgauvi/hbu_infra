# ---------------------------------------------------------------------------
# Who is allowed to reach port 5432
#
# Three sources, all optional and all additive:
#
#   1. the public IP of whoever ran `terraform apply` (var.allow_current_ip,
#      the address itself in var.current_ip)
#   2. any extra ranges named in var.allowed_cidr_blocks
#   3. the bastion's security group, when var.enable_bastion is on
#
# With none of them set the database is created with no ingress at all, which
# is a working — if useless — configuration rather than an error.
# ---------------------------------------------------------------------------

# The address arrives as a variable rather than from a `data "http"` lookup:
# behind a TLS-inspecting proxy the hashicorp/http provider cannot be installed
# at all (Zscaler serves a block page instead of the release zip), which fails
# `terraform init` for everyone on the network — including dev, where this
# feature is off. The Makefile does the same lookup with one curl. See `make plan`.
locals {
  # Empty means nobody filled it in; the precondition below turns that into a
  # readable failure rather than the nonsense CIDR "/32".
  current_ip_cidr = var.allow_current_ip && var.current_ip != "" ? ["${var.current_ip}/32"] : []
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

    # Catch the combination at plan time. Without this the group would come up
    # silently missing the one rule the operator asked for.
    precondition {
      condition     = !var.allow_current_ip || var.current_ip != ""
      error_message = "allow_current_ip is true but current_ip is empty. Run `make plan ENV=${var.environment}`, which looks the address up, or pass -var current_ip=<address> yourself."
    }
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

# The application tasks reach the database by security-group reference rather
# than by CIDR, because a Fargate task's address is assigned at start and
# changes on every deploy. This is also what lets the database stay in the
# private tier with no public endpoint while the app talks to it.
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  count = var.enable_app ? 1 : 0

  security_group_id            = aws_security_group.db.id
  description                  = "Postgres from the application tasks"
  referenced_security_group_id = aws_security_group.app[0].id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
