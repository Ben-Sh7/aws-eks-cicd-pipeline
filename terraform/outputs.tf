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

# Instructions only - never the password itself, even as a sensitive output.
output "grafana_access_instructions" {
  value       = <<-EOT
    kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
    http://localhost:3000 - user: admin, password: your TF_VAR_grafana_admin_password
  EOT
  description = "How to reach Grafana (ClusterIP only)"
}

output "argocd_access_instructions" {
  value       = <<-EOT
    kubectl port-forward -n argocd svc/argocd-server 8081:443
    https://localhost:8081 - user: admin, password:
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
  EOT
  description = "How to reach ArgoCD (ClusterIP only)"
}
