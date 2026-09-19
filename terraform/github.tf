locals {
  github_repo_parts = split("/", local.github_repo)
  github_owner      = length(local.github_repo_parts) == 2 ? local.github_repo_parts[0] : ""
  github_repo_name  = length(local.github_repo_parts) == 2 ? local.github_repo_parts[1] : ""
}

resource "github_repository_webhook" "jenkins" {
  repository = local.github_repo_name
  active     = true
  events     = ["push"]

  configuration {
    url          = "http://${local.jenkins_fqdn}:8080/github-webhook/"
    content_type = "json"
    insecure_ssl = false
    secret       = random_password.jenkins_webhook.result
  }

  depends_on = [aws_route53_record.jenkins]
}

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
