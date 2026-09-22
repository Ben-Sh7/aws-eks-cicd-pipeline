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

variable "rds_backup_retention_days" {
  description = "Days of automated RDS backups. Automated backups are deleted together with the instance, so this leaves nothing behind after a destroy. 0 turns them off."
  type        = number
  default     = 7
}

variable "app_db_username" {
  description = "Postgres role the application logs in as. Created on first sync by a job inside the cluster, because the database is private and Terraform cannot reach it."
  type        = string
  default     = "app_user"
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
  description = "Node count at creation only. The autoscaler owns it from then on, so Terraform ignores later drift - see the lifecycle block on the node group."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Floor the autoscaler may not go below. Two rather than one because EBS volumes belong to a single availability zone: Prometheus, Grafana and Alertmanager can only start on a node in the zone their volume was created in, and the group balances across both."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Ceiling the autoscaler may not go above. The limit that stops a runaway workload from becoming a runaway bill."
  type        = number
  default     = 4
}

variable "node_max_pods" {
  description = "Pods a node may run. The IP-per-pod default is 17 on t3.medium, which the add-ons alone nearly fill; prefix delegation lifts the address limit and this lifts kubelet's. Kept well under what the addresses now allow, because 4 GiB of memory runs out before the addresses do."
  type        = number
  default     = 50
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

variable "metrics_server_chart_version" {
  description = "Pinned metrics-server chart version. Supplies the live cpu and memory readings that a HorizontalPodAutoscaler scales on; without it `kubectl top` and every HPA sit blind."
  type        = string
  default     = "3.12.2"
}

variable "cluster_autoscaler_chart_version" {
  description = "Pinned cluster-autoscaler chart version. Adds a node when a pod cannot be scheduled and removes one that is no longer needed."
  type        = string
  default     = "9.43.2"
}

variable "scale_down_unneeded_time" {
  description = "How long a node must look unneeded before the autoscaler removes it. Short values thrash; long values pay for idle nodes."
  type        = string
  default     = "10m"
}

variable "scale_down_delay_after_add" {
  description = "Quiet period after a scale-up before any scale-down is considered, so a burst does not immediately undo itself."
  type        = string
  default     = "10m"
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

variable "alertmanager_storage_size" {
  description = "PVC size for Alertmanager. Without one its silences live in an emptyDir and are lost whenever the pod moves."
  type        = string
  default     = "1Gi"
}

variable "monthly_budget_usd" {
  description = "Monthly spend that triggers a budget notification. The alert is the point - it arrives before the bill does."
  type        = number
  default     = 50
}

variable "jenkins_ui_allowed_cidrs" {
  description = "CIDRs allowed to reach the Jenkins UI on 8080. Left empty, Terraform allows exactly the public IP it is running from (looked up at plan time, see data.http.my_ip in main.tf) - never 0.0.0.0/0. GitHub's webhook ranges are allowed separately and do not belong here."
  type        = list(string)
  default     = []
}

variable "enable_slack_alerts" {
  description = "Whether Alertmanager routes warning/critical alerts to Slack. The URL itself never passes through Terraform: External Secrets reads SLACK_WEBHOOK_URL out of the credentials entry you maintain by hand and Alertmanager reads it from a mounted file. false leaves Alertmanager on the chart default (a null receiver)."
  type        = bool
  default     = true
}

variable "slack_channel" {
  description = "Channel Alertmanager posts to. Only used when enable_slack_alerts is true; the webhook URL already targets a channel, this just overrides it."
  type        = string
  default     = "#alerts"
}

variable "app_subdomain" {
  description = "Subdomain the app is served on, or \"\" to serve it on the domain itself. This is the address users open and the only origin the frontend accepts sign-ins from. The zone apex cannot hold a CNAME, which is why every record here is an ALIAS."
  type        = string
  default     = ""
}

variable "argocd_subdomain" {
  description = "Subdomain for the one ArgoCD path published to the internet (/api/webhook). The UI and the rest of the API stay ClusterIP - see argocd-webhook.tf."
  type        = string
  default     = "argocd"
}

variable "jenkins_subdomain" {
  description = "Subdomain pointing at the Jenkins EC2 instance. Gives the GitHub webhook a target that survives the instance getting a new public IP."
  type        = string
  default     = "jenkins"
}

variable "aws_profile" {
  description = "Named AWS profile to authenticate with, for both the AWS provider and the `aws eks get-token` calls the Kubernetes and Helm providers make. Empty (the default) uses whatever `aws configure` set up, which is the normal case here. Pass -var=aws_profile=... only when juggling several accounts."
  type        = string
  default     = ""
}

variable "argocd_apps_chart_version" {
  description = "Pinned argocd-apps Helm chart version. Creates the Application; kept separate from the argo-cd release because a chart cannot create a custom resource whose CRD it installs in that same release."
  type        = string
  default     = "2.0.2"
}
