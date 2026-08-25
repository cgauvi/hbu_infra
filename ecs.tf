# ---------------------------------------------------------------------------
# Fargate service — the Streamlit front end
#
# Where the tasks run is the one non-obvious choice here. They sit in the
# *public* subnets with a public IP, not in the private tier, because the app
# makes outbound HTTPS calls the VPC has no other way to serve: every chat
# turn and every query embedding goes to the HuggingFace Inference API, and
# the image itself is pulled from ECR over the internet.
#
# The alternatives both cost more than they are worth here. A NAT gateway is
# roughly $32/month before data processing — more than the database it would
# be sitting next to. VPC endpoints for ECR, S3, logs and Secrets Manager are
# cheaper than that but solve only the pull; nothing reaches huggingface.co
# through them, so the app would start and then fail on its first question.
#
# "Public subnet" is a routing fact, not an exposure one: the task security
# group accepts inbound only from the ALB, so the public IP carries egress
# and answers nothing.
# ---------------------------------------------------------------------------

locals {
  app_name = "${local.prefix}-rag-map"

  # try(), because a per-env stack applied against a shared stack that predates
  # the ECR repository would otherwise fail on a missing output rather than on
  # the thing actually wrong — which is that `make apply-shared` has not been
  # re-run. With enable_app = false nothing reads this and the empty string is
  # never used.
  ecr_url   = try(data.terraform_remote_state.shared.outputs.ecr_repository_url, "")
  app_image = "${local.ecr_url}:${var.app_image_tag}"
}

resource "aws_ecs_cluster" "main" {
  count = var.enable_app ? 1 : 0

  name = local.prefix

  setting {
    name  = "containerInsights"
    value = var.app_container_insights ? "enabled" : "disabled"
  }
}

# ---------------------------------------------------------------------------
# Networking for the tasks
# ---------------------------------------------------------------------------

resource "aws_security_group" "app" {
  count = var.enable_app ? 1 : 0

  name        = "${local.prefix}-app-sg"
  description = "Application tasks - inbound from the ALB only"
  vpc_id      = data.terraform_remote_state.shared.outputs.vpc_id

  tags = { Name = "${local.prefix}-app-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  count = var.enable_app ? 1 : 0

  security_group_id            = aws_security_group.app[0].id
  description                  = "Streamlit from the load balancer"
  referenced_security_group_id = aws_security_group.alb[0].id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

# Outbound is wide because the destinations are: ECR and its S3 layer store,
# CloudWatch Logs, Secrets Manager, SSM, the RDS endpoint, and HuggingFace —
# the last of which resolves to a CDN with no stable address to pin.
resource "aws_vpc_security_group_egress_rule" "app_all" {
  count = var.enable_app ? 1 : 0

  security_group_id = aws_security_group.app[0].id
  description       = "Outbound to ECR, CloudWatch, Secrets Manager, RDS and the HuggingFace API"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Secrets the container is handed at start
#
# Both follow the pattern ssm.tf established for the app-role password:
# Terraform owns the secret, not the value. The placeholder is written once
# and ignore_changes keeps a later apply from reverting whatever was put there
# by `make app-password` or `make app-hf-token` — so a rotated token never has
# to pass through a plan and never lands in state.
# ---------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "app_password" {
  count = var.enable_app ? 1 : 0

  name        = "${local.prefix}/app/access-password"
  description = "Shared password the ${local.prefix} front end asks for before showing the map"

  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "app_password" {
  count = var.enable_app ? 1 : 0

  secret_id     = aws_secretsmanager_secret.app_password[0].id
  secret_string = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret" "hf_token" {
  count = var.enable_app ? 1 : 0

  name        = "${local.prefix}/app/hf-token"
  description = "HuggingFace Inference API token - the chat model and the query encoder both use it"

  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "hf_token" {
  count = var.enable_app ? 1 : 0

  secret_id     = aws_secretsmanager_secret.hf_token[0].id
  secret_string = "PLACEHOLDER"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# There is deliberately no Terraform check that the placeholders have been
# replaced. Asserting it would mean reading the values with an
# aws_secretsmanager_secret_version *data* source, and a data source writes
# what it reads into the state file — putting the password in S3 to prove it
# is not a placeholder. The check belongs where it costs nothing: auth.py
# refuses to accept any login while the value is still "PLACEHOLDER", and says
# which target sets it.

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  count = var.enable_app ? 1 : 0

  name              = "/ecs/${local.app_name}"
  retention_in_days = var.app_log_retention_days
}

# ---------------------------------------------------------------------------
# IAM — two roles, deliberately
#
# The execution role belongs to the ECS agent: it pulls the image, resolves
# the `secrets` below into environment variables, and writes the log stream.
# It is not available to code running inside the container.
#
# The task role is what the application's own boto3 calls assume. It gets the
# db-access policy ssm.tf publishes and nothing else — notably not read on the
# HuggingFace token, which the agent injects and the app never fetches.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app_execution" {
  count = var.enable_app ? 1 : 0

  name               = "${local.prefix}-app-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "app_execution" {
  count = var.enable_app ? 1 : 0

  role       = aws_iam_role.app_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The managed policy above covers ECR and logs but stops short of Secrets
# Manager, because AWS cannot know which secrets a task is entitled to. Name
# the two.
data "aws_iam_policy_document" "app_execution_secrets" {
  count = var.enable_app ? 1 : 0

  statement {
    sid     = "ReadInjectedSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.app_password[0].arn,
      aws_secretsmanager_secret.hf_token[0].arn,
    ]
  }
}

resource "aws_iam_role_policy" "app_execution_secrets" {
  count = var.enable_app ? 1 : 0

  name   = "${local.prefix}-app-execution-secrets"
  role   = aws_iam_role.app_execution[0].id
  policy = data.aws_iam_policy_document.app_execution_secrets[0].json
}

resource "aws_iam_role" "app_task" {
  count = var.enable_app ? 1 : 0

  name               = "${local.prefix}-app-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# The whole database contract in one attachment: the /<prefix>/db/* parameters
# the app discovers its endpoint from, and the app-role secret it resolves the
# password from. Defined in ssm.tf precisely so this file does not repeat it.
resource "aws_iam_role_policy_attachment" "app_task_db" {
  count = var.enable_app ? 1 : 0

  role       = aws_iam_role.app_task[0].name
  policy_arn = aws_iam_policy.db_access.arn
}

# ECS Exec — `make app-shell` opens a shell in a running task without a
# bastion or an SSH key, over the same SSM channel the bastion uses.
data "aws_iam_policy_document" "app_task_exec" {
  count = var.enable_app && var.app_enable_execute_command ? 1 : 0

  statement {
    sid    = "SsmMessagesForEcsExec"
    effect = "Allow"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "app_task_exec" {
  count = var.enable_app && var.app_enable_execute_command ? 1 : 0

  name   = "${local.prefix}-app-task-exec"
  role   = aws_iam_role.app_task[0].id
  policy = data.aws_iam_policy_document.app_task_exec[0].json
}

# ---------------------------------------------------------------------------
# Task definition
#
# Note what is *not* here: no host, no port, no database password, no env name
# baked into the image. HBU_PROJECT and HBU_ENV are the two halves of the SSM
# prefix, and src/utils/db.py discovers the rest underneath it — so replacing
# the RDS instance changes nothing in this file and needs no redeploy.
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "app" {
  count = var.enable_app ? 1 : 0

  family                   = local.app_name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.app_cpu
  memory                   = var.app_memory
  execution_role_arn       = aws_iam_role.app_execution[0].arn
  task_role_arn            = aws_iam_role.app_task[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.app_cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "app"
      image     = local.app_image
      essential = true

      portMappings = [
        {
          containerPort = var.app_port
          protocol      = "tcp"
        }
      ]

      environment = [
        # The SSM prefix, and the region boto3 resolves it in. Everything
        # about the database follows from these.
        { name = "HBU_PROJECT", value = var.project_name },
        { name = "HBU_ENV", value = var.environment },
        { name = "AWS_REGION", value = var.aws_region },
        { name = "AWS_DEFAULT_REGION", value = var.aws_region },

        # verify-full, not require: the image carries Amazon's RDS root bundle
        # at this path, so the server is authenticated and not merely
        # encrypted to. Dropping to `require` would accept any certificate.
        { name = "URBAN_RAG_PG_SSLMODE", value = "verify-full" },
        { name = "URBAN_RAG_PG_SSLROOTCERT", value = "/etc/ssl/certs/rds-global-bundle.pem" },
        { name = "URBAN_RAG_PG_USER", value = var.app_db_username },

        # "prod" hides the sidebar log pane, which is a debugging aid and not
        # something a shared password should be the only thing in front of.
        { name = "APP_ENV", value = var.app_env_mode },
        { name = "LOG_LEVEL", value = var.app_log_level },
      ]

      secrets = [
        {
          name      = "HBU_APP_PASSWORD"
          valueFrom = aws_secretsmanager_secret.app_password[0].arn
        },
        {
          name      = "HUGGINGFACE_API_TOKEN"
          valueFrom = aws_secretsmanager_secret.hf_token[0].arn
        },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app[0].name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "app"
        }
      }

      # The image's own HEALTHCHECK is a Docker instruction Fargate ignores;
      # restating it here is what recycles a task whose Streamlit server has
      # wedged while its process is still alive. The ALB would stop routing to
      # it either way, but only this replaces it.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:${var.app_port}/_stcore/health')\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
    }
  ])
}

# ---------------------------------------------------------------------------
# The service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "app" {
  count = var.enable_app ? 1 : 0

  name            = local.app_name
  cluster         = aws_ecs_cluster.main[0].id
  task_definition = aws_ecs_task_definition.app[0].arn
  desired_count   = var.app_desired_count
  launch_type     = "FARGATE"

  enable_execute_command = var.app_enable_execute_command

  network_configuration {
    subnets = data.terraform_remote_state.shared.outputs.public_subnet_ids
    # Required, not optional: with no public IP there is no route to ECR and
    # the task fails to pull before it ever runs. See the note at the top.
    assign_public_ip = true
    security_groups  = [aws_security_group.app[0].id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app[0].arn
    container_name   = "app"
    container_port   = var.app_port
  }

  # Streamlit's cold start is slow — imports first, then the SSM and Secrets
  # Manager round trips. Without the grace period ECS kills the task on a
  # health check it was never going to pass in time, forever.
  health_check_grace_period_seconds = 120

  # A task definition pointing at a tag that does not exist, or an image that
  # crashes on boot, would otherwise leave the service retrying indefinitely
  # with the previous deployment already drained. This rolls back instead.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # 100/200 starts the replacement before draining the old task, so even a
  # one-task service has no gap. The cost is briefly two tasks' worth of
  # Fargate, which is what zero-downtime costs at this size.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Fail `terraform apply` on a broken image rather than returning success and
  # leaving the breakage to be found in a browser.
  wait_for_steady_state = var.app_wait_for_steady_state

  # The listener has to exist before the service registers targets behind it.
  depends_on = [aws_lb_listener.http]

  lifecycle {
    # `make app-scale` and any autoscaling set this out of band; Terraform
    # should not read that as drift to revert on the next apply.
    ignore_changes = [desired_count]
  }
}
