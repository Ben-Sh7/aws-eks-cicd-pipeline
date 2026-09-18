# The two push webhooks on this repo, owned by Terraform.
#
# They used to be created by curl from a shell script, which meant
# reimplementing by hand what Terraform does for free: list the existing hooks,
# work out whether to POST a new one or PATCH the old one, and check every HTTP
# status because curl exits 0 on a 404. With the hooks as resources, the state
# file knows which hook belongs to this project, `terraform plan` shows a drift
# if someone edits one in the GitHub UI, and `terraform destroy` removes them
# instead of leaving hooks pointing at addresses that now belong to somebody
# else.
#
# Neither hook is required for the system to work. ArgoCD polls git every 180s
# and Jenkins can be built by hand; the webhooks only collapse those waits into
# seconds.

#
# One quirk to expect: GitHub never returns a webhook secret over its API, only
# a row of asterisks, so a plan can report an in-place update on these two even
# when nothing changed. Applying it re-sends the same value and is harmless -
# and it is preferable to silencing the field with ignore_changes, which would
# also silence a real rotation and leave GitHub signing with a key the receiver
# no longer knows.

locals {
  # GITHUB_REPO comes from the configuration secret as "owner/repo". The check
  # block in external-config.tf catches it being absent; this catches it being
  # present but malformed, before the split produces a confusing index error.
  github_repo_parts = split("/", local.github_repo)
  github_owner      = length(local.github_repo_parts) == 2 ? local.github_repo_parts[0] : ""
  github_repo_name  = length(local.github_repo_parts) == 2 ? local.github_repo_parts[1] : ""
}

# Jenkins verifies GitHub's HMAC signature over the payload using this secret
# (set on the Jenkins side by the Groovy bootstrap), so an unsigned POST that
# gets past the security group is still dropped.
resource "github_repository_webhook" "jenkins" {
  repository = local.github_repo_name
  active     = true
  events     = ["push"]

  configuration {
    # Plain HTTP: Jenkins serves 8080 without TLS, and putting it behind the
    # cluster's load balancer would mean exposing CI to the internet to save a
    # webhook. The payload is public source anyway; the signature is what
    # matters, and it is computed over the body, not the transport.
    url          = "http://${local.jenkins_fqdn}:8080/github-webhook/"
    content_type = "json"
    insecure_ssl = false
    secret       = random_password.jenkins_webhook.result
  }

  depends_on = [aws_route53_record.jenkins]
}

# Same idea for ArgoCD, over HTTPS, against the single path published for it.
resource "github_repository_webhook" "argocd" {
  repository = local.github_repo_name
  active     = true
  events     = ["push"]

  configuration {
    url          = "https://${local.argocd_fqdn}/api/webhook"
    content_type = "json"
    insecure_ssl = false
    secret       = random_password.argocd_webhook.result
  }

  depends_on = [
    aws_route53_record.argocd,
    kubernetes_ingress_v1.argocd_webhook,
  ]
}
