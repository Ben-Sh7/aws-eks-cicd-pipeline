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

variable "private_subnet_1_cidr" {
  description = "Private subnet 1 CIDR block (RDS)"
  type        = string
  default     = "10.0.11.0/24"
}

variable "private_subnet_2_cidr" {
  description = "Private subnet 2 CIDR block (RDS)"
  type        = string
  default     = "10.0.12.0/24"
}

variable "rds_engine_version" {
  description = "Postgres major version - AWS picks the latest minor"
  type        = string
  default     = "16"
}

variable "rds_instance_class" {
  description = "RDS instance class (db.t4g.micro is free-tier eligible)"
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_allocated_storage" {
  description = "RDS storage in GB (20 is the free-tier maximum)"
  type        = number
  default     = 20
}

variable "rds_db_name" {
  description = "Database name created inside the RDS instance"
  type        = string
  default     = "tasksdb"
}

variable "rds_username" {
  description = "RDS master username"
  type        = string
  default     = "postgres"
}

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

variable "prometheus_storage_size" {
  description = "PVC size for Prometheus metrics"
  type        = string
  default     = "10Gi"
}

variable "prometheus_retention" {
  description = "How long Prometheus keeps metrics"
  type        = string
  default     = "15d"
}

variable "grafana_storage_size" {
  description = "PVC size for Grafana dashboards/settings"
  type        = string
  default     = "5Gi"
}

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

variable "jenkins_ui_allowed_cidrs" {
  description = "CIDRs allowed to reach the Jenkins UI on 8080. create.sh sets this to the public IP it runs from; GitHub's webhook ranges are allowed separately and do not belong here. Empty means the UI is unreachable, which is the safe default rather than 0.0.0.0/0."
  type        = list(string)
  default     = []
}

variable "slack_webhook_url" {
  description = "Slack Incoming Webhook URL for Alertmanager. Empty (the default) leaves Alertmanager on the chart default - a null receiver - so the project still comes up with one command and no Slack account. Set it in .env as TF_VAR_slack_webhook_url to route alerts to Slack. It lives only in .env (gitignored) and local state."
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_channel" {
  description = "Channel Alertmanager posts to. Only used when slack_webhook_url is set; the webhook already targets a channel, this just overrides it."
  type        = string
  default     = "#alerts"
}

variable "github_pat" {
  description = "GitHub Personal Access Token (repo + admin:repo_hook scopes). Required, no default - bootstraps the Jenkins job/credential and lets create.sh manage the GitHub webhook."
  type        = string
  sensitive   = true
}

