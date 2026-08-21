# ---------------------------------------------------------------------------
# Scheduled stop/start
#
# EventBridge Scheduler calls the RDS API directly through its universal
# target, so this costs one IAM role and two schedules — no Lambda to package,
# version, or debug at 22:00.
#
# Two things worth knowing before turning it on:
#   - Storage and backups are billed while an instance is stopped; only the
#     instance hours stop. On a t4g.micro that is most of the bill, not all.
#   - RDS force-starts anything left stopped for 7 days. A daily start cron
#     means that never fires, but a paused schedule will let it.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume" {
  count = var.enable_scheduled_shutdown ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    # Without this, any account able to create a schedule could borrow the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count = var.enable_scheduled_shutdown ? 1 : 0

  name               = "${local.prefix}-db-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume[0].json
}

data "aws_iam_policy_document" "scheduler" {
  count = var.enable_scheduled_shutdown ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["rds:StopDBInstance", "rds:StartDBInstance"]
    resources = [aws_db_instance.main.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  count = var.enable_scheduled_shutdown ? 1 : 0

  name   = "${local.prefix}-db-scheduler"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler[0].json
}

resource "aws_scheduler_schedule" "stop" {
  count = var.enable_scheduled_shutdown ? 1 : 0

  name                         = "${local.prefix}-db-stop"
  description                  = "Stop ${local.prefix} overnight"
  schedule_expression          = var.stop_cron
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance"
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({ DbInstanceIdentifier = aws_db_instance.main.identifier })

    retry_policy {
      maximum_retry_attempts = 3
    }
  }
}

resource "aws_scheduler_schedule" "start" {
  count = var.enable_scheduled_shutdown ? 1 : 0

  name                         = "${local.prefix}-db-start"
  description                  = "Start ${local.prefix} in the morning"
  schedule_expression          = var.start_cron
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:rds:startDBInstance"
    role_arn = aws_iam_role.scheduler[0].arn
    input    = jsonencode({ DbInstanceIdentifier = aws_db_instance.main.identifier })

    retry_policy {
      maximum_retry_attempts = 3
    }
  }
}
