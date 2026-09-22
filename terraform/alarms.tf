resource "aws_sns_topic" "alerts" {
  name              = "${local.project_name}-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = local.common_tags
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count = local.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = local.alert_email
}

locals {
  rds_alarms = {
    cpu = {
      metric      = "CPUUtilization"
      comparison  = "GreaterThanThreshold"
      threshold   = 80
      unit        = "Percent"
      description = "RDS CPU above 80% for 10 minutes"
    }
    storage = {
      metric      = "FreeStorageSpace"
      comparison  = "LessThanThreshold"
      threshold   = 2 * 1024 * 1024 * 1024
      unit        = "Bytes"
      description = "Less than 2 GB of RDS storage left"
    }
    memory = {
      metric      = "FreeableMemory"
      comparison  = "LessThanThreshold"
      threshold   = 128 * 1024 * 1024
      unit        = "Bytes"
      description = "Less than 128 MB of freeable memory on RDS"
    }
    connections = {
      metric      = "DatabaseConnections"
      comparison  = "GreaterThanThreshold"
      threshold   = 40
      unit        = "Count"
      description = "More than 40 open database connections"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each = local.rds_alarms

  alarm_name          = "${local.project_name}-rds-${each.key}"
  alarm_description   = each.value.description
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  unit                = each.value.unit
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  tags          = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "jenkins_status_check" {
  alarm_name          = "${local.project_name}-jenkins-status-check"
  alarm_description   = "The Jenkins instance is failing an EC2 status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = aws_instance.jenkins.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  tags          = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "jenkins_cpu" {
  alarm_name          = "${local.project_name}-jenkins-cpu"
  alarm_description   = "Jenkins CPU above 85% for 15 minutes - a build is stuck or the instance is undersized"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  unit                = "Percent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.jenkins.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  tags          = local.common_tags
}

resource "aws_budgets_budget" "monthly" {
  name         = "${local.project_name}-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = { forecasted = "FORECASTED", actual = "ACTUAL" }

    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = 80
      threshold_type            = "PERCENTAGE"
      notification_type         = notification.value
      subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
    }
  }
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "budgets.amazonaws.com"]
    }

    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}
