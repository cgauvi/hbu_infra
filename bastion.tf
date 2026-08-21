# ---------------------------------------------------------------------------
# Optional SSM bastion
#
# Only created when var.enable_bastion is true — the path for a database with
# no public endpoint. It has no keypair, no inbound rules, and no public port:
# Session Manager reaches it outbound-only through the SSM endpoints, and
# `make db-tunnel` port-forwards 5432 across that session.
#
# Access is therefore IAM, revoked by removing a permission rather than by
# rotating a key that may already be on three laptops.
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "bastion_ami" {
  count = var.enable_bastion ? 1 : 0
  # Amazon Linux 2023, arm64 — ships the SSM agent enabled, which is the only
  # thing this host has to run.
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name        = "${local.prefix}-bastion-sg"
  description = "SSM bastion — egress only; Session Manager needs no inbound rule"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = { Name = "${local.prefix}-bastion-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_egress_rule" "bastion_all" {
  count = var.enable_bastion ? 1 : 0

  security_group_id = aws_security_group.bastion[0].id
  description       = "Outbound to the SSM endpoints and to the database"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

data "aws_iam_policy_document" "bastion_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name               = "${local.prefix}-bastion-role"
  assume_role_policy = data.aws_iam_policy_document.bastion_assume.json
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  count = var.enable_bastion ? 1 : 0

  role       = aws_iam_role.bastion[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# So a shell opened on the bastion can resolve the endpoint and password the
# same way a laptop does, instead of needing them pasted in.
resource "aws_iam_role_policy_attachment" "bastion_db_access" {
  count = var.enable_bastion ? 1 : 0

  role       = aws_iam_role.bastion[0].name
  policy_arn = aws_iam_policy.db_access.arn
}

resource "aws_iam_instance_profile" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name = "${local.prefix}-bastion-profile"
  role = aws_iam_role.bastion[0].name
}

resource "aws_instance" "bastion" {
  count = var.enable_bastion ? 1 : 0

  ami                    = data.aws_ssm_parameter.bastion_ami[0].value
  instance_type          = var.bastion_instance_type
  iam_instance_profile   = aws_iam_instance_profile.bastion[0].name
  vpc_security_group_ids = [aws_security_group.bastion[0].id]

  # Public subnet with a public IP: the SSM agent has to reach the Session
  # Manager endpoints, and this VPC has no NAT gateway. Nothing can reach the
  # host inbound — the security group has no ingress rule at all.
  subnet_id                   = data.terraform_remote_state.shared.outputs.public_subnet_ids[0]
  associate_public_ip_address = true

  # psql on the host, for the times a tunnel is more trouble than a shell.
  user_data = <<-EOT
    #!/bin/bash
    dnf install -y postgresql16
  EOT

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${local.prefix}-bastion" }
}
