resource "aws_sns_topic" "alerts" {
  name = "${local.project_name}-alerts"
  tags = local.common_tags
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count = local.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = local.alert_email
}

resource "aws_sns_topic" "heartbeat" {
  name = "${local.project_name}-heartbeat"
  tags = local.common_tags
}

data "aws_iam_policy_document" "alertmanager_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url_no_scheme}:sub"
      values   = ["system:serviceaccount:monitoring:${local.alertmanager_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alertmanager" {
  name_prefix        = "${local.project_name}-alertmanager-"
  assume_role_policy = data.aws_iam_policy_document.alertmanager_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "alertmanager_publish" {
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn, aws_sns_topic.heartbeat.arn]
  }
}

resource "aws_iam_role_policy" "alertmanager_publish" {
  name   = "${local.project_name}-alertmanager-publish"
  role   = aws_iam_role.alertmanager.id
  policy = data.aws_iam_policy_document.alertmanager_publish.json
}

resource "aws_cloudwatch_metric_alarm" "alerting_heartbeat" {
  alarm_name          = "${local.project_name}-alerting-heartbeat"
  alarm_description   = "Alertmanager stopped sending its heartbeat - alerting itself is down, and silence means nothing"
  namespace           = "AWS/SNS"
  metric_name         = "NumberOfMessagesPublished"
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  statistic           = "Sum"
  period              = 900
  evaluation_periods  = 1
  treat_missing_data  = "breaching"

  dimensions = {
    TopicName = aws_sns_topic.heartbeat.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
  tags          = local.common_tags

  depends_on = [helm_release.kube_prometheus_stack]
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
