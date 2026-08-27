# ---------------------------------------------------------------------------
# Application load balancer
#
# The ALB is the only thing in this stack with a public address. It lives in
# the shared public subnets, terminates the client connection, and forwards to
# task IPs in the same VPC — which is what lets the tasks themselves refuse
# every inbound packet that does not come from this security group.
#
# Streamlit is not a request/response app: after the initial GET it holds a
# websocket open for the life of the tab, and every widget interaction is a
# frame on that socket. Two consequences are configured below — stickiness, so
# a reconnecting socket lands back on the task holding its session state, and
# an idle timeout longer than a user's thinking pause.
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  count = var.enable_app ? 1 : 0

  name        = "${local.prefix}-alb-sg"
  description = "Public ingress for ${local.prefix} - the only internet-facing SG in this stack"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = { Name = "${local.prefix}-alb-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = var.enable_app ? toset(var.app_ingress_cidr_blocks) : toset([])

  security_group_id = aws_security_group.alb[0].id
  description       = "HTTP from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = var.enable_app && var.app_certificate_arn != "" ? toset(var.app_ingress_cidr_blocks) : toset([])

  security_group_id = aws_security_group.alb[0].id
  description       = "HTTPS from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# The ALB reaches the tasks, and nothing else. Scoped to the task security
# group rather than to the VPC CIDR so it stays true if other things move in.
resource "aws_vpc_security_group_egress_rule" "alb_to_tasks" {
  count = var.enable_app ? 1 : 0

  security_group_id            = aws_security_group.alb[0].id
  description                  = "Forward to the application tasks"
  referenced_security_group_id = aws_security_group.app[0].id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

resource "aws_lb" "app" {
  count = var.enable_app ? 1 : 0

  name               = "${local.prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = data.terraform_remote_state.shared.outputs.public_subnet_ids
  security_groups    = [aws_security_group.alb[0].id]

  # Streamlit's websocket carries no traffic while someone reads an answer.
  # At the ALB default of 60s that silence closes the socket and the browser
  # shows "connection lost" mid-session.
  idle_timeout = var.app_idle_timeout

  # Drops requests whose headers ELB and the target would parse differently,
  # rather than passing the ambiguity through to Streamlit.
  desync_mitigation_mode = "defensive"

  drop_invalid_header_fields = true
  enable_deletion_protection = var.app_deletion_protection

  tags = { Name = "${local.prefix}-alb" }
}

resource "aws_lb_target_group" "app" {
  count = var.enable_app ? 1 : 0

  # name_prefix, not name, and the prefix is truncated because AWS caps a
  # target group's name_prefix at six characters. The reason is the lifecycle
  # block at the bottom: a target group cannot be deleted while a listener
  # still forwards to it, so any change that forces a replacement — the port,
  # the protocol, the target type — has to create the new one first, and two
  # target groups cannot share a name. The readable name is in the tag.
  name_prefix = substr(local.prefix, 0, 6)

  # Fargate tasks in awsvpc mode are registered by IP, not by instance.
  port        = var.app_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  # Streamlit answers 200 here as soon as the server is up — it does not wait
  # on the database, which is what you want: a task that cannot reach Postgres
  # should show its own error, not be killed and replaced forever.
  health_check {
    path                = "/_stcore/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # Session state lives in the task's memory. Without stickiness a rerun can
  # land on a different task, which reads as the app forgetting the selected
  # lot and the whole conversation.
  stickiness {
    type            = "lb_cookie"
    enabled         = true
    cookie_duration = var.app_session_duration
  }

  # Long enough to let an in-flight answer finish streaming, short enough that
  # a deploy is not held open by an idle tab.
  deregistration_delay = 30

  tags = { Name = "${local.prefix}-tg" }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Listeners
#
# With no certificate this is a plain port 80 listener and the password the
# app asks for crosses the wire in the clear. Setting app_certificate_arn to
# an ACM certificate turns 80 into a redirect and moves the forward to 443 —
# in place, without replacing the load balancer or its DNS name.
# ---------------------------------------------------------------------------

resource "aws_lb_listener" "http" {
  count = var.enable_app ? 1 : 0

  load_balancer_arn = aws_lb.app[0].arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = var.app_certificate_arn == "" ? [1] : []
    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.app[0].arn
    }
  }

  dynamic "default_action" {
    for_each = var.app_certificate_arn != "" ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count = var.enable_app && var.app_certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_lb.app[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.app_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[0].arn
  }
}

# A warning rather than an error, because HTTP-only is a reasonable place to
# start and a deliberate one to stay in behind a VPN. It stops being reasonable
# the moment the listener is open to the world and the app asks for a password.
check "app_password_in_the_clear" {
  assert {
    condition = (
      !var.enable_app
      || var.app_certificate_arn != ""
      || !contains(var.app_ingress_cidr_blocks, "0.0.0.0/0")
    )
    error_message = "The app is open to 0.0.0.0/0 over plain HTTP, so the shared password is sent unencrypted and is readable by anything on the path. Set app_certificate_arn to an ACM certificate, or narrow app_ingress_cidr_blocks."
  }
}
