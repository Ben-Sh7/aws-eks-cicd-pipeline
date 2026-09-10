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

output "jenkins_public_ip" {
  value       = aws_instance.jenkins.public_ip
  description = "Jenkins public IP (use http://<IP>:8080)"
}

output "github_repo" {
  value       = var.github_repo
  description = "GitHub repo (owner/repo) - used by create.sh to manage the webhook"
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

# Both are only known after apply, and both change on every create.sh run -
# create.sh feeds them to the chart as ArgoCD helm parameters.
output "rds_endpoint" {
  value       = aws_db_instance.postgres.address
  description = "RDS Postgres hostname - the app's DB_HOST"
}

output "rds_master_secret_name" {
  value       = aws_db_instance.postgres.master_user_secret[0].secret_arn
  description = "ARN of the AWS-managed RDS master secret that External Secrets reads"
}

# Instructions only - never the password itself, even as a sensitive output.
output "grafana_access_instructions" {
  value       = <<-EOT
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
    http://localhost:3000 - user: admin, password:
      aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.grafana_admin.name} --query SecretString --output text
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

output "argocd_webhook_secret_name" {
  description = "Secrets Manager entry holding the shared secret GitHub signs ArgoCD webhook payloads with. create.sh reads it to register the hook; the value is never printed."
  value       = aws_secretsmanager_secret.argocd_webhook.name
}

output "jenkins_webhook_secret_name" {
  description = "Secrets Manager entry holding the shared secret GitHub signs Jenkins webhook payloads with. create.sh reads it to register the hook; the value is never printed."
  value       = aws_secretsmanager_secret.jenkins_webhook.name
}

output "nat_gateway_public_ip" {
  description = "The single public IP all worker-node egress leaves from now that the nodes are in private subnets. This is the address to allowlist if the cluster calls a third-party API that filters by source IP."
  value       = aws_eip.nat.public_ip
}

output "slack_alerting" {
  description = "Whether Alertmanager routes to Slack. 'disabled' means it is on the chart default (null receiver); set TF_VAR_slack_webhook_url in .env to enable."
  value       = local.slack_alerting_enabled ? "enabled (channel ${var.slack_channel})" : "disabled - set TF_VAR_slack_webhook_url"
}
