# ============================================
# Terraform Variables - Easy Configuration
# ============================================
# Change these values to customize your deployment

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name (used in resource naming and tags, e.g. the EKS cluster name)"
  type        = string
  default     = "task-manager"
}

variable "environment" {
  description = "Environment (learning, staging, production)"
  type        = string
  default     = "learning"
}

# ============================================
# VPC Configuration
# ============================================
variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_1_cidr" {
  description = "Public subnet 1 CIDR block"
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_subnet_2_cidr" {
  description = "Public subnet 2 CIDR block"
  type        = string
  default     = "10.0.2.0/24"
}

# ============================================
# EKS Configuration
# ============================================
variable "kubernetes_version" {
  description = "Kubernetes version for EKS cluster"
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS nodes"
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

# ============================================
# EC2 Configuration (Jenkins)
# ============================================
variable "jenkins_instance_type" {
  description = "EC2 instance type for Jenkins"
  type        = string
  default     = "t2.medium"
}

variable "jenkins_root_volume_size" {
  description = "Root volume size for Jenkins EC2 (GB)"
  type        = number
  default     = 20
}

# ============================================
# Helm Add-ons (ingress-nginx, kube-prometheus-stack, argocd, external-secrets)
# ============================================
variable "ingress_nginx_chart_version" {
  description = "Pinned ingress-nginx Helm chart version"
  type        = string
  default     = "4.11.3"
}

variable "kube_prometheus_stack_chart_version" {
  description = "Pinned kube-prometheus-stack Helm chart version"
  type        = string
  default     = "65.5.1"
}

variable "argocd_chart_version" {
  description = "Pinned argo-cd Helm chart version (CD - GitOps sync from this repo)"
  type        = string
  default     = "7.7.11"
}

variable "external_secrets_chart_version" {
  description = "Pinned external-secrets Helm chart version (syncs AWS Secrets Manager into K8s Secrets via IRSA)"
  type        = string
  default     = "0.10.4"
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Required, no default - set via TF_VAR_grafana_admin_password."
  type        = string
  sensitive   = true
}

# ============================================
# Jenkins Bootstrap (auto-provisioning)
# ============================================
variable "github_repo" {
  description = "GitHub repo this project lives in, as owner/repo"
  type        = string
  default     = "Ben-Sh7/aws-eks-cicd-pipeline"
}

variable "github_username" {
  description = "GitHub username associated with github_pat"
  type        = string
  default     = "Ben-Sh7"
}

variable "github_pat" {
  description = "GitHub Personal Access Token (repo + admin:repo_hook scopes). Required, no default - bootstraps the Jenkins job/credential and lets create.sh manage the GitHub webhook."
  type        = string
  sensitive   = true
}

variable "jenkins_admin_password" {
  description = "Jenkins admin login password. Required, no default - fails closed instead of leaving Jenkins with no authentication."
  type        = string
  sensitive   = true
}
