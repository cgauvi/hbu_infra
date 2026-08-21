data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  prefix = var.project_name
}

# ---------------------------------------------------------------------------
# VPC — shared between every environment
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.prefix}-vpc" }
}

# ---------------------------------------------------------------------------
# Subnets
#
# Two tiers, both created here so a per-env stack can pick one without
# reshaping the VPC:
#
#   public  — has a default route to the IGW. An RDS instance placed here can
#             be given a public endpoint (publicly_accessible = true), which is
#             what makes `make db-psql` work from a laptop with no bastion.
#   private — no route off the VPC at all. An RDS instance here is reachable
#             only from inside the VPC (ECS tasks, or the SSM bastion).
#
# There is deliberately NO NAT gateway: nothing in the private tier needs
# outbound internet, and a NAT would cost more per month than the database.
# ---------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${local.prefix}-public-${count.index + 1}" }
}

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 101)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = { Name = "${local.prefix}-private-${count.index + 1}" }
}

# ---------------------------------------------------------------------------
# Internet Gateway + route tables
# ---------------------------------------------------------------------------

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.prefix}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# The private route table carries only the implicit local route. It exists as
# its own resource so private subnets are never accidentally associated with
# the public one by falling through to the VPC's main route table.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# DB subnet groups — one per tier.
#
# Both are created up front because a DB subnet group cannot be edited to move
# an instance between tiers; the per-env stack selects one by name via
# var.db_subnet_tier. Switching that variable replaces the instance, which is
# the honest cost of moving a database from public to private.
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "public" {
  name        = "${local.prefix}-public"
  description = "Public subnets — for an RDS instance with publicly_accessible = true"
  subnet_ids  = aws_subnet.public[*].id
}

resource "aws_db_subnet_group" "private" {
  name        = "${local.prefix}-private"
  description = "Private subnets — for an RDS instance reachable only from inside the VPC"
  subnet_ids  = aws_subnet.private[*].id
}
