output "aws_region" {
  value       = var.aws_region
  description = "AWS region resources were deployed to"
}

output "vpc_id" {
  value       = aws_vpc.main.id
  description = "VPC ID"
}

output "eks_cluster_name" {
  value       = aws_eks_cluster.main.name
  description = "EKS cluster name"
}

output "eks_cluster_endpoint" {
  value       = aws_eks_cluster.main.endpoint
  description = "EKS cluster endpoint"
}

output "app_url" {
  value       = local.app_url
  description = "The address users open. Live once the first Jenkins build has pushed images and ArgoCD has synced them - about ten minutes after apply finishes."
}

output "jenkins_url" {
  value       = "http://${local.jenkins_fqdn}:8080"
  description = "Jenkins UI (user: admin). Reachable from the IP the apply ran from, and from GitHub's webhook ranges - nowhere else."
}

output "jenkins_public_ip" {
  value       = aws_instance.jenkins.public_ip
  description = "Jenkins public IP, behind the DNS record above"
}

output "github_repo" {
  value       = local.github_repo
  description = "GitHub repo (owner/repo) the CI and GitOps flow is wired to"
}

output "backend_repository_url" {
  value       = aws_ecr_repository.backend.repository_url
  description = "Backend ECR repository URL"
}

output "frontend_repository_url" {
  value       = aws_ecr_repository.frontend.repository_url
  description = "Frontend ECR repository URL"
}

output "external_secrets_role_arn" {
  value       = aws_iam_role.external_secrets.arn
  description = "IRSA role bound to the external-secrets ServiceAccount"
}

output "rds_endpoint" {
  value       = aws_db_instance.postgres.address
  description = "RDS Postgres hostname - the app's DB_HOST"
}

output "rds_master_secret_name" {
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
  description = "ARN of the AWS-managed RDS master secret that External Secrets reads"
}

output "grafana_access_instructions" {
  value       = <<-EOT
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
    http://localhost:3000 - then read the login from AWS:
      aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.grafana_admin.name} --query SecretString --output text
    (returns {"admin-user":"admin","admin-password":"..."} - Terraform generated
     it without ever holding it, so AWS is the only place it exists)
  EOT
  description = "How to reach Grafana (ClusterIP only)"
}

output "jenkins_password_command" {
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.jenkins_admin.name} --query SecretString --output text"
  description = "Reads the generated Jenkins admin password"
}

output "argocd_access_instructions" {
  value       = <<-EOT
    kubectl port-forward -n argocd svc/argocd-server 8081:443
    https://localhost:8081 - user: admin, password:
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  EOT
  description = "How to reach ArgoCD (ClusterIP only)"
}

output "kubeconfig_command" {
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
  description = "Points kubectl at this cluster. Not needed for the system to run - only for looking at it."
}

output "jwt_secret_name" {
  description = "Secrets Manager entry holding the key the backend signs access tokens with. External Secrets copies the value into the cluster; it is never printed."
  value       = aws_secretsmanager_secret.jwt_secret.name
}

output "nat_gateway_public_ip" {
  description = "The single public IP all worker-node egress leaves from now that the nodes are in private subnets. This is the address to allowlist if the cluster calls a third-party API that filters by source IP."
  value       = aws_eip.nat.public_ip
}

output "credentials_secret" {
  description = "The Secrets Manager entry the cluster reads Slack and Google credentials from, and the JSON shape expected in it. Keys may be left out; each missing one only switches its own feature off."
  value       = <<-EOT
    ${data.aws_secretsmanager_secret.app.name}

    aws secretsmanager put-secret-value --secret-id ${data.aws_secretsmanager_secret.app.name} --secret-string '{
      "SLACK_WEBHOOK_URL":    "https://hooks.slack.com/services/...",
      "GOOGLE_CLIENT_ID":     "....apps.googleusercontent.com",
      "GOOGLE_CLIENT_SECRET": "..."
    }'

    External Secrets re-reads it hourly, so a change lands within the hour -
    immediately if the pod that consumes it is restarted.
  EOT
}

output "google_redirect_uri" {
  description = "Register this on the Google OAuth client, or Google refuses to return users to the app. It is derived from the domain, so it only changes if the domain does."
  value       = "${local.app_url}/api/auth/callback"
}

output "slack_alerting" {
  description = "Whether Alertmanager is configured to route to Slack. 'enabled' means the routing exists - delivery also needs the real URL from slack_webhook_setup."
  value       = var.enable_slack_alerts ? "enabled (channel ${var.slack_channel})" : "disabled - set enable_slack_alerts = true"
}
