# DevOps Task Manager

> Push code. Everything else — build, deploy, secrets, monitoring — happens by itself.

A task manager (React + Node/Express + PostgreSQL) deployed on AWS EKS, with GitOps CI/CD and infrastructure as code.

## Quick Start

**Prerequisites**: `terraform`, `aws`, `kubectl`, `docker`, `jq`, and AWS credentials the CLI can reach.

Create `.env` in the project root with:
```
AWS_PROFILE=<your AWS profile>         # omit only if your creds are on [default]
TF_VAR_github_pat=<your GitHub PAT>    # repo + admin:repo_hook scopes
POSTGRES_PASSWORD=<your password>      # local docker-compose only
```
Those three are all you supply. Everything else is generated for you: Terraform creates Grafana's and Jenkins' admin passwords and the two shared secrets GitHub signs its webhooks with - one for Jenkins, one for ArgoCD - straight into AWS Secrets Manager, and AWS itself generates and rotates the database password. You never choose or handle any of them; `terraform output` names the Secrets Manager entry for each.

`create.sh` also detects the public IP it is running from and opens the Jenkins UI to that address only. Port 8080 is otherwise reachable only from GitHub's published webhook ranges, and there is no SSH rule at all - the instance is reached through SSM Session Manager. If your IP changes, re-run `create.sh`, or set `TF_VAR_jenkins_ui_allowed_cidrs='["x.x.x.x/32"]'` yourself.

On IAM Identity Center (SSO) the profile alone isn't enough - log in first, or every AWS call fails:
```bash
aws sso login --profile <your AWS profile>
```

```bash
# 1. Spin up everything: infra + Jenkins (fully configured) + add-ons + app
./create.sh

# 2. When done - tear down everything, no orphaned resources
./destroy.sh
```

`create.sh`/`destroy.sh` both auto-load `.env` if it exists. See [.env.example](.env.example) for details on each variable.

## Creating the GitHub token

`TF_VAR_github_pat` is the one credential you create by hand. Two things need
it: Jenkins clones this repo and pushes the image-tag bump back, and `create.sh`
creates and re-points the repo's webhooks on every run.

1. Open <https://github.com/settings/tokens> and pick the **Tokens (classic)** tab.
2. **Generate new token → Generate new token (classic)**. GitHub will ask you to
   re-authenticate.
3. **Note**: something you will recognise later, e.g. `devops-task-manager`.
4. **Expiration**: pick a real date - 30 days is plenty. Avoid *No expiration*;
   a token that never dies is a token you never rotate.
5. Tick exactly two scopes:
   - **`repo`** - Jenkins clones the repository and pushes the `ci: deploy X`
     commit that tells ArgoCD which image to run.
   - **`admin:repo_hook`** - `create.sh` creates the Jenkins and ArgoCD webhooks
     and re-points them at the new addresses on every run. Without it the API
     returns 403 and a push triggers nothing.
6. **Generate token**, then copy the `ghp_...` string immediately - GitHub shows
   it once and never again.
7. Paste it into `.env` as the value of `TF_VAR_github_pat`. Paste the token
   itself, not the URL of the page you created it on.

`create.sh` checks the token against the GitHub API before it creates any
infrastructure and prints the scopes it actually has, so a wrong or expired
token fails in seconds instead of 25 minutes into a `terraform apply`.

A fine-grained token works too: give it access to this repository with
**Contents: Read and write** and **Webhooks: Read and write**. Fine-grained
tokens do not report their scopes over the API, so `create.sh` can confirm only
that the token is valid, not that its permissions are sufficient.

## How It Works

1. **Push code** to `main` → GitHub webhook fires (auto-managed by `create.sh` - it re-points at the Jenkins EC2's IP on every run)
2. **Jenkins (CI)** builds the Docker image, pushes it to ECR, bumps the image tag in `gitops/task-manager/values-images.yaml`, and pushes that back to the repo
3. **ArgoCD (CD)** is notified by a webhook, pulls the change, and deploys the app to EKS - Jenkins never touches the cluster. Only ArgoCD's `/api/webhook` path is published through the ingress; its UI and API stay internal, and payloads must be signed with a secret Terraform generates. If the webhook is ever unavailable, ArgoCD's own 180-second poll still picks the change up
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
- **CD**: ArgoCD (GitOps, pull-based, webhook-triggered)
- **Secrets**: External Secrets Operator + IRSA ← AWS Secrets Manager
- **Ingress**: ingress-nginx
- **Monitoring**: Prometheus + Grafana (kube-prometheus-stack)

## Database

Postgres runs on **RDS**, in private subnets, reachable only from the EKS nodes' security group. AWS generates and rotates the master password in Secrets Manager itself - it never passes through Terraform state or git - and External Secrets Operator pulls it into the cluster via IRSA. There is no manual setup step.
