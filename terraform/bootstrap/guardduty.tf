variable "config_secret_name" {
  description = "Secrets Manager entry holding this deployment's plain configuration. Only ALERT_EMAIL is read here, to tell GuardDuty's findings where to go."
  type        = string
  default     = "task-manager/config"
}

data "aws_secretsmanager_secret" "config" {
  name = var.config_secret_name
}

data "aws_secretsmanager_secret_version" "config" {
  secret_id = data.aws_secretsmanager_secret.config.id
}

locals {
  security_tags = {
    Project   = "task-manager"
    Purpose   = "security-monitoring"
    ManagedBy = "IaC"
  }

  alert_email = lookup(
    try(jsondecode(nonsensitive(data.aws_secretsmanager_secret_version.config.secret_string)), {}),
    "ALERT_EMAIL",
    "",
  )
}

resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  tags                         = local.security_tags
}

resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "s3_data_events" {
  detector_id = aws_guardduty_detector.main.id
  name        = "S3_DATA_EVENTS"
  status      = "DISABLED"
}

resource "aws_guardduty_detector_feature" "ebs_malware_protection" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "DISABLED"
}

resource "aws_sns_topic" "security" {
  name = "task-manager-security"
  tags = local.security_tags
}

resource "aws_sns_topic_subscription" "security_email" {
  count = local.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.security.arn
  protocol  = "email"
  endpoint  = local.alert_email
}

data "aws_iam_policy_document" "security_topic" {
  statement {
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [aws_sns_topic.security.arn]
  }
}

resource "aws_sns_topic_policy" "security" {
  arn    = aws_sns_topic.security.arn
  policy = data.aws_iam_policy_document.security_topic.json
}

resource "aws_cloudwatch_event_rule" "guardduty_findings" {
  name        = "task-manager-guardduty-findings"
  description = "GuardDuty findings of medium severity and above"
  tags        = local.security_tags

  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 4] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_findings_email" {
  rule      = aws_cloudwatch_event_rule.guardduty_findings.name
  target_id = "security-email"
  arn       = aws_sns_topic.security.arn

  input_transformer {
    input_paths = {
      severity    = "$.detail.severity"
      type        = "$.detail.type"
      description = "$.detail.description"
      region      = "$.region"
      time        = "$.time"
    }

    input_template = "\"GuardDuty severity <severity>: <type>\\n\\n<description>\\n\\n<region> at <time>\""
  }
}

output "security_monitoring" {
  value = <<-EOT
    GuardDuty is on for this account and stays on: it keeps watching CloudTrail,
    VPC flow logs, DNS and the EKS audit log while the stack is destroyed.

    Findings of medium severity and above go to ${local.alert_email == "" ? "nowhere - add ALERT_EMAIL to ${var.config_secret_name}" : local.alert_email}.
  EOT
}
