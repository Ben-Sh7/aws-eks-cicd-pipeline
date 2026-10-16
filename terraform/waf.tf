resource "aws_wafv2_ip_set" "jenkins_allowed" {
  name               = "${local.project_name}-jenkins-allowed"
  description        = "GitHub webhook ranges plus whoever runs the apply, IPv4"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = concat(local.github_hook_cidrs, local.operator_cidrs)
  tags               = local.common_tags
}

resource "aws_wafv2_ip_set" "argocd_allowed" {
  name               = "${local.project_name}-argocd-allowed"
  description        = "GitHub webhook ranges, IPv4, read from api.github.com/meta at plan time"
  scope              = "REGIONAL"
  ip_address_version = "IPV4"
  addresses          = local.github_hook_cidrs
  tags               = local.common_tags
}

locals {
  # Requests are checked in this order; the first rule that blocks ends it.
  waf_host_allowlists = {
    jenkins = {
      priority = 0
      host     = local.jenkins_fqdn
      ip_set   = aws_wafv2_ip_set.jenkins_allowed.arn
    }
    argocd = {
      priority = 1
      host     = local.argocd_fqdn
      ip_set   = aws_wafv2_ip_set.argocd_allowed.arn
    }
  }

  # AWS-maintained rule groups, applied to the app only. The common rule set
  # refuses bodies over 8 KB, which would drop GitHub's larger webhook payloads,
  # and both tool hosts are already closed to everyone but GitHub and you.
  waf_managed_groups = {
    AWSManagedRulesAmazonIpReputationList = 3
    AWSManagedRulesCommonRuleSet          = 4
  }
}

resource "aws_wafv2_web_acl" "main" {
  name        = local.project_name
  description = "In front of the ALB: tool allowlists, a per-IP rate limit, AWS rule groups on the app"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.waf_host_allowlists
    content {
      name     = "${rule.key}-allowlist"
      priority = rule.value.priority

      action {
        block {}
      }

      statement {
        and_statement {
          statement {
            byte_match_statement {
              search_string         = rule.value.host
              positional_constraint = "EXACTLY"

              field_to_match {
                single_header {
                  name = "host"
                }
              }

              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }

          statement {
            not_statement {
              statement {
                ip_set_reference_statement {
                  arn = rule.value.ip_set
                }
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "${local.project_name}-${rule.key}-allowlist"
      }
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        aggregate_key_type    = "IP"
        evaluation_window_sec = 300
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      sampled_requests_enabled   = true
      metric_name                = "${local.project_name}-rate-limit"
    }
  }

  dynamic "rule" {
    for_each = local.waf_managed_groups
    content {
      name     = rule.key
      priority = rule.value

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key

          scope_down_statement {
            byte_match_statement {
              search_string         = local.app_fqdn
              positional_constraint = "EXACTLY"

              field_to_match {
                single_header {
                  name = "host"
                }
              }

              text_transformation {
                priority = 0
                type     = "LOWERCASE"
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        sampled_requests_enabled   = true
        metric_name                = "${local.project_name}-${rule.key}"
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    sampled_requests_enabled   = true
    metric_name                = local.project_name
  }

  tags = local.common_tags
}

# WAF log group names must start with aws-waf-logs-. Owned by Terraform so the
# destroy takes it, with a short retention: this is for looking at recent
# blocks, the way the nginx access log was.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${local.project_name}"
  retention_in_days = 3
  tags              = local.common_tags
}

data "aws_caller_identity" "current" {}

# Declared here rather than left for WAF to add on its own, so it is removed
# with the stack instead of lingering in the account.
data "aws_iam_policy_document" "waf_logs_delivery" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.waf.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf" {
  policy_name     = "${local.project_name}-waf-logs"
  policy_document = data.aws_iam_policy_document.waf_logs_delivery.json
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Session tokens travel in these two headers; the log keeps everything else.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }

  depends_on = [aws_cloudwatch_log_resource_policy.waf]
}
