# DevOps Task Manager

> Push code. Everything else — build, deploy, secrets, monitoring — happens by itself.

A task manager (React + Node/Express + PostgreSQL) deployed on AWS EKS, with GitOps CI/CD and infrastructure as code.

## Quick Start

Create `.env` in the project root with:
```
POSTGRES_USER=postgres
POSTGRES_PASSWORD=<your password>
POSTGRES_DB=tasksdb
TF_VAR_grafana_admin_password=<your password>
TF_VAR_jenkins_admin_password=<your password>
TF_VAR_github_pat=<your GitHub PAT>
```

```bash
# 1. Spin up everything: infra + Jenkins (fully configured) + add-ons + app
./create.sh

# 2. When done - tear down everything, no orphaned resources
./destroy.sh
```

`create.sh`/`destroy.sh` both auto-load `.env` if it exists. See [.env.example](.env.example) for the three required variables (`TF_VAR_grafana_admin_password`, `TF_VAR_jenkins_admin_password`, `TF_VAR_github_pat`) and where each one is used.

## How It Works

1. **Push code** to `main` → GitHub webhook fires (auto-managed by `create.sh` - it re-points at the Jenkins EC2's IP on every run)
2. **Jenkins (CI)** builds the Docker image, pushes it to ECR, bumps the image tag in `gitops/task-manager/values-images.yaml`, and pushes that back to the repo
3. **ArgoCD (CD)** notices the change, pulls it, and deploys the app to EKS - Jenkins never touches the cluster
4. **External Secrets Operator** pulls DB credentials from AWS Secrets Manager straight into the cluster - no secret ever passes through git or Jenkins
5. **Prometheus + Grafana** watch the cluster the whole time

Jenkins itself is fully self-configuring: `terraform apply` provisions the EC2 with a `user_data` script that installs Jenkins/Docker, and a Groovy init script that creates the admin login, the GitHub credential, and the Pipeline job automatically on first boot - no manual clicking through the Jenkins UI.

## Architecture

See [HLD.md](HLD.md) for the full design document.

## Tech Stack

- **App**: React, Node.js/Express, PostgreSQL
- **Infrastructure as Code**: Terraform (VPC, EKS, EC2, ECR, IAM, OIDC)
- **Packaging**: Helm
- **CI**: Jenkins (build + push only), with Trivy scanning every image for CVEs before push
- **CD**: ArgoCD (GitOps, pull-based)
- **Secrets**: External Secrets Operator + IRSA ← AWS Secrets Manager
- **Ingress**: ingress-nginx
- **Monitoring**: Prometheus + Grafana (kube-prometheus-stack)

## One-Time AWS Setup

```bash
# Create the DB credentials secret (External Secrets Operator syncs this automatically)
aws secretsmanager create-secret --name app-secrets --region us-east-1 \
  --secret-string '{"DB_USER":"postgres","DB_PASSWORD":"your-secure-password"}'
```
