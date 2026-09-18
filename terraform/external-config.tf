# Everything this deployment needs to know about the outside world, read from
# AWS Secrets Manager at plan time.
#
# There is no tfvars file and no .env: no domain, no repository, and above all
# no token is written down anywhere on the machine running Terraform. You create
# these three entries once, by hand (see README -> "One-time setup"), and they
# outlive every `terraform destroy` - which is the other half of the point.
# Terraform generates and destroys its own secrets with the stack, but these
# belong to you, not to the stack.
#
# Three entries and not one, because three different readers need them and none
# of them should be able to read the others':
#
#   task-manager/config         plain configuration - Terraform only
#   task-manager/secrets        Slack + Google - the External Secrets operator
#   task-manager/github-token   the token - Terraform (in memory) and Jenkins
#
# If a name here does not exist, the plan stops on "couldn't find resource" and
# names the entry it was looking for.

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

# ---------------------------------------------------------------------------
# Configuration. Read normally, which means it is recorded in state - and that
# is correct: a domain name and a repository path are public facts about the
# deployment, not secrets. Keeping them here rather than in a variables file is
# about having one place to look, not about hiding them.
# ---------------------------------------------------------------------------

data "aws_secretsmanager_secret" "config" {
  name = var.config_secret_name
}

data "aws_secretsmanager_secret_version" "config" {
  secret_id = data.aws_secretsmanager_secret.config.id

  # Validated as it is read, so a half-filled entry stops the plan here with one
  # readable message - rather than surfacing as a Route53 zone that cannot be
  # found, a GitHub repository that does not exist, and seven other errors that
  # do not mention the real cause. try() also covers the entry not being valid
  # JSON at all.
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
  # try(): the postcondition above is the place that explains a malformed entry,
  # and it cannot do that if evaluating this line panics first.
  config = try(jsondecode(data.aws_secretsmanager_secret_version.config.secret_string), {})

  # lookup with a default rather than a bare attribute: a missing key then
  # surfaces as the precondition below, which says what to do about it, instead
  # of "this object does not have an attribute named GITHUB_REPO".
  domain_name     = lookup(local.config, "DOMAIN_NAME", "")
  github_repo     = lookup(local.config, "GITHUB_REPO", "")
  github_username = lookup(local.config, "GITHUB_USERNAME", "")
}

# ---------------------------------------------------------------------------
# Credentials.
# ---------------------------------------------------------------------------

# Only the ARN, for the IAM policies that let the External Secrets operator read
# it (irsa.tf). Terraform never reads the value: Slack and Google reach the
# cluster without passing through it at all.
data "aws_secretsmanager_secret" "app" {
  name = var.secrets_secret_name
}

# Same, for the entry Jenkins reads at boot (jenkins.tf).
data "aws_secretsmanager_secret" "github_token" {
  name = var.github_token_secret_name
}

# The token itself, for the github provider.
#
# `ephemeral` is the whole reason this works: the value is fetched when it is
# needed and discarded afterwards. Unlike a data source, nothing about it is
# written to the state file or to a saved plan - which is what let the token
# stop being a Terraform input, and is why `terraform destroy` no longer needs
# one either.
#
# An ephemeral value may only be used where Terraform can guarantee it is not
# persisted - provider configuration, write-only arguments, other ephemeral
# resources. That is also why DOMAIN_NAME and GITHUB_REPO above are read the
# ordinary way: they are used in resource arguments, which an ephemeral value is
# not allowed to reach.
ephemeral "aws_secretsmanager_secret_version" "github_token" {
  secret_id = data.aws_secretsmanager_secret.github_token.id
}

# A note on what is NOT here: nothing writes to these three entries. Terraform
# creating them would mean Terraform owning their lifecycle, and `terraform
# destroy` would then take your Slack URL and your Google client with it - which
# is exactly the property worth avoiding, since the point of keeping them
# outside the stack is that a rebuild asks you for nothing.
