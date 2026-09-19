variable "config_secret_name" {
  description = "Secrets Manager entry holding this deployment's plain configuration as JSON: DOMAIN_NAME, GITHUB_REPO, GITHUB_USERNAME."
  type        = string
  default     = "task-manager/config"
}

variable "secrets_secret_name" {
  description = "Secrets Manager entry holding the credentials the cluster consumes as JSON: SLACK_WEBHOOK_URL, GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET. Terraform never reads it - only the External Secrets operator does, and only the properties the chart asks for."
  type        = string
  default     = "task-manager/secrets"
}

variable "github_token_secret_name" {
  description = "Secrets Manager entry holding the GitHub token as a plain string. Read into memory during apply to configure the github provider, and read at boot by the Jenkins instance. Never written to state."
  type        = string
  default     = "task-manager/github-token"
}

data "aws_secretsmanager_secret" "config" {
  name = var.config_secret_name
}

data "aws_secretsmanager_secret_version" "config" {
  secret_id = data.aws_secretsmanager_secret.config.id

  lifecycle {
    postcondition {
      condition = alltrue([
        for key in ["DOMAIN_NAME", "GITHUB_REPO", "GITHUB_USERNAME"] :
        try(jsondecode(self.secret_string)[key], "") != ""
      ])
      error_message = "The ${var.config_secret_name} secret must be a JSON object with non-empty DOMAIN_NAME, GITHUB_REPO (as owner/repo) and GITHUB_USERNAME. See README -> One-time setup."
    }
  }
}

locals {
  config = try(jsondecode(data.aws_secretsmanager_secret_version.config.secret_string), {})

  domain_name     = lookup(local.config, "DOMAIN_NAME", "")
  github_repo     = lookup(local.config, "GITHUB_REPO", "")
  github_username = lookup(local.config, "GITHUB_USERNAME", "")
}

data "aws_secretsmanager_secret" "app" {
  name = var.secrets_secret_name
}

data "aws_secretsmanager_secret" "github_token" {
  name = var.github_token_secret_name
}

ephemeral "aws_secretsmanager_secret_version" "github_token" {
  secret_id = data.aws_secretsmanager_secret.github_token.id
}

