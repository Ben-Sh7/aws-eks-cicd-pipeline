# DevOps Task Manager

> Push code. Everything else — build, deploy, secrets, monitoring — happens by itself.

A task manager (Next.js + NestJS + PostgreSQL) on AWS EKS. GitOps CI/CD, all infrastructure as code.

---

## Architecture

See **[HLD.md](HLD.md)** — diagrams, security design, and the reasoning behind each choice.

---

## Quick Start

**You need:** `terraform`, the `aws` CLI, AWS credentials, and a domain in a Route53 hosted zone. *(Those two are all the deployment uses. `kubectl` is for looking at the cluster afterwards.)*

There is no configuration file to fill in and nothing secret on your machine. Everything this deployment needs to know — the domain, the repository, the GitHub token, the Slack and Google credentials — lives in **AWS Secrets Manager**, created once and read at plan time.

### One-time setup

Done once per AWS account. None of it is part of the stack — `terraform destroy` touches none of it, so a rebuild never asks you for anything again.

**a. The three Secrets Manager entries:**

```bash
# 1. Plain configuration. Not secret - just the facts about this deployment.
aws secretsmanager create-secret --name task-manager/config --secret-string '{
  "DOMAIN_NAME":     "example.com",
  "GITHUB_REPO":     "your-user/your-repo",
  "GITHUB_USERNAME": "your-user"
}'

# 2. Credentials the cluster consumes. Both keys are optional - each one only
#    switches its own feature on. See "Signing in" and "Alerting".
aws secretsmanager create-secret --name task-manager/secrets --secret-string '{
  "SLACK_WEBHOOK_URL":    "https://hooks.slack.com/services/...",
  "GOOGLE_CLIENT_ID":     "....apps.googleusercontent.com",
  "GOOGLE_CLIENT_SECRET": "..."
}'

# 3. The GitHub token, on its own. See "GitHub token" below.
aws secretsmanager create-secret --name task-manager/github-token --secret-string 'ghp_...'
```

Three entries rather than one because three different readers need them, and none of them should be able to read the others': Terraform reads the configuration, and the External Secrets operator reads the credentials and hands Jenkins the token it pushes with.

Add `"ALERT_EMAIL": "you@example.com"` to the first entry to receive the alerts and the security findings. Without it they are raised and delivered nowhere.

**b. The bootstrap stack.** Terraform's state is the only record of what exists in the account, and it holds generated passwords, so it does not belong on a laptop. This creates an S3 bucket for it with versioning, KMS encryption, no public access and TLS enforced - and switches GuardDuty on for the account:

```bash
cd terraform/bootstrap
terraform init && terraform apply
cd ../..
```

*(S3 bucket names are globally unique. If that one is taken, change `state_bucket_name` in `terraform/bootstrap/main.tf` and `bucket` in `terraform/backend.tf` to match.)*

GuardDuty lives here rather than in the stack so that it keeps watching the account while the stack is destroyed. It is free for 30 days, then a few dollars a month for an account this size. Storage costs $0.40 per secret per month, plus $1/month for the state bucket's KMS key.

### Every time

```bash
aws configure            # or: aws sso login --profile <name>

cd terraform
terraform init
terraform plan
terraform apply          # ~25 min

terraform destroy        # tears it all down
```

That is the whole deployment. One command builds the network, the cluster, the database, CI, CD, monitoring, DNS and the certificate, registers both GitHub webhooks, and starts the first Jenkins build — because the image registry is empty on a fresh build and nothing else would trigger one. About ten minutes later the app is live at `https://app.<your domain>`.

`terraform output` prints every address and the command to look up each password.

Afterwards, to confirm the account is clean:

```bash
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=task-manager
```

Everything carries that tag, including the load balancer and the EBS volumes Kubernetes creates. An empty result means nothing was left behind.

> Running the stack on your own machine is a separate thing entirely — see [Working on the code](#working-on-the-code). The deployment reads nothing from your disk.

### Rotating what Terraform generates

The JWT signing key and the Jenkins and Grafana admin passwords are generated during apply and written straight to Secrets Manager with **write-only arguments** — Terraform hands them to AWS without recording them in state, which means it cannot show them to you afterwards and neither can anyone reading the state file. AWS is the only place they exist.

To roll all three, increment one number:

```bash
terraform apply -var="generated_secret_version=2"
```

The app and Grafana pick the new value up from External Secrets within the hour, or immediately on pod restart; Jenkins applies its new password when its pod restarts. Rotating the JWT key signs everyone out, by design.

The two webhook signing secrets are the exception: Terraform has to hand the *same* value to GitHub and to the receiver, so it must hold them, and they are in state. That is what the encrypted, versioned, access-controlled bucket in step (a) is for — protecting state is the answer here, not pretending it can be emptied.

### The domain

This is the one prerequisite you cannot generate. Terraform needs a **public Route53 hosted zone that already exists and is delegated** — registering a domain through Route53 gives you both; a domain registered elsewhere needs its nameservers pointed at a Route53 zone once, at the registrar.

From that one name Terraform derives every address in the system — `app.`, `argocd.`, `jenkins.` — and issues one ACM certificate covering them. That is what makes a single command enough: nothing has to be discovered after the fact and fed back in, and the app's own address stops changing on every rebuild.

### What's generated for you

You create the three entries above. Everything below is generated during apply and kept in Secrets Manager — you never see or choose any of it.

| Generated for you | |
|---|---|
| TLS certificate | ACM, renewed automatically |
| Grafana + Jenkins admin passwords | `terraform output` prints the lookup commands |
| Two webhook signing secrets | GitHub signs each payload; an unsigned POST is dropped |
| JWT signing key | Signs the app's sessions |
| RDS password | Created **and rotated** by AWS itself |

---

## GitHub token

You create this one by hand. Jenkins needs it to push, and Terraform needs it to manage the repo's webhooks.

1. Go to <https://github.com/settings/tokens> → **Tokens (classic)**
2. **Generate new token (classic)**
3. **Expiration:** 30 days. Not "never"
4. Tick two scopes: **`repo`** and **`admin:repo_hook`**
5. Copy the `ghp_...` string now — GitHub shows it once
6. Put it in Secrets Manager — step 3 of [One-time setup](#one-time-setup)

> The token is never a Terraform variable, never in a file, and never in the state file: Terraform reads it into memory during apply to register the webhooks (an `ephemeral` resource, which Terraform is not allowed to persist), and External Secrets syncs it into the cluster for Jenkins to push with.

<details>
<summary>Why those two scopes, and using a fine-grained token</summary>

<br>

**`repo`** lets Jenkins clone the repo and push the `ci: deploy X` commit. That commit is how ArgoCD learns which image to run.

**`admin:repo_hook`** lets Terraform create and update the two webhooks. Without it the API returns 403 and the apply fails there.

**Fine-grained tokens** work too. Give it access to this repo with **Contents: Read and write** and **Webhooks: Read and write**.

</details>

---

## Signing in

Open the app and **create an account with a username and password**.

- Passwords are stored as **argon2id** hashes — never the password itself
- A session is a 15-minute access token plus a refresh token that rotates on every use, both in `httpOnly` cookies the page's JavaScript cannot read
- Reusing an already-rotated refresh token counts as theft and ends every session of that account

> **The deployed app runs over HTTPS.** TLS terminates on the load balancer with an ACM certificate AWS renews on its own, and plain HTTP is redirected. The private key is never issued to anyone, this project included.

### Google sign-in

Two steps, both one-time:

1. Register the redirect URI on your Google OAuth client — `terraform output google_redirect_uri` prints it (`https://app.<your domain>/api/auth/callback`)
2. Put `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` in the credentials entry — `terraform output credentials_secret` prints the command and the JSON shape

The External Secrets operator copies them into the cluster from there, and the sign-in button appears. The values never pass through Terraform, the state file, or any file on your machine.

Leave the keys out and the app runs with username + password accounts only: the backend refuses every Google token and the button stays hidden.

---

## How It Works

```
git push → Jenkins builds & scans → ECR → Jenkins commits the tag → ArgoCD deploys
```

**1. You push.** A GitHub webhook fires.

**2. Jenkins builds and scans.** Trivy is a gate, not a report — a fixable HIGH or CRITICAL CVE fails the build and nothing reaches ECR.

**3. Jenkins writes the new tag to Git.** This is the handoff. Jenkins cannot deploy - its identity reaches two ECR repositories and nothing else in the cluster - so Git is how it tells ArgoCD what to run.

**4. ArgoCD deploys.** A second webhook wakes it, and it syncs the chart to EKS. The backend applies any new database migrations as it starts.

**5. Secrets arrive on their own.** External Secrets Operator pulls the DB credentials and the JWT signing key from Secrets Manager into the cluster. No secret ever passes through Git or Jenkins.

**6. Monitoring runs throughout.** Prometheus, Grafana, and Alertmanager. Put `SLACK_WEBHOOK_URL` in the credentials entry and warning + critical alerts go to Slack — Alertmanager reads it from a file the operator writes, so the URL never appears in a Helm value or in Terraform state.

<details>
<summary>Details on the webhooks, the first build, alert filtering, and Jenkins' self-setup</summary>

<br>

**The webhooks are Terraform resources.** Both are declared in `terraform/github.tf`, so an apply creates or corrects them, a destroy removes them, and a plan shows it if somebody edits one in the GitHub UI. They point at DNS names, not at IP addresses, so replacing the Jenkins instance does not invalidate them.

**The first build starts itself.** ECR is recreated empty on every build, and a push is normally what starts a job — so the Groovy script that creates the job also queues its first run. If it ever fails, press **Build Now** in Jenkins.

**Jenkins skips its own commits.** A build started by a push whose last commit is the `ci: deploy` bump is skipped, so the pipeline cannot trigger itself forever. A build started any other way always runs.

**ArgoCD stays private.** Only its `/api/webhook` path is exposed through the ingress — the UI and API are not. Payloads must be signed with a secret Terraform generates. If the webhook is ever down, ArgoCD's own 180-second poll catches the change anyway.

**Alert noise is filtered.** `Watchdog` and `InfoInhibitor` are dropped. So are the chart's scheduler, controller-manager and etcd rules — EKS runs those on AWS's side where nothing can scrape them, so they'd report "down" forever.

**Jenkins configures itself.** No setup wizard. `terraform apply` runs a `user_data` script that installs Jenkins and Docker, plus a Groovy script that creates the admin login, the GitHub credential, and the pipeline job on first boot. The three secrets it needs are pulled from Secrets Manager at boot with the instance's own IAM role — user-data itself carries no secret, because anything in it can be read back from the metadata service by every process on the host.

</details>

---

## Watching it happen

| | Where | How to get there |
|---|---|---|
| **The app** | `https://app.<domain>` | `terraform output app_url` |
| **Jenkins** | `https://jenkins.<domain>` | Open from your IP — nobody else can reach it |
| **ArgoCD** | `https://localhost:8081` | `kubectl port-forward -n argocd svc/argocd-server 8081:443` |
| **Grafana** | `http://localhost:3000` | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` |

`terraform output` prints all of these, with the command that reads each password.

**Who may reach Jenkins:** your IP and GitHub's webhook ranges. Nothing else — the ingress refuses the rest.

If your IP changes, re-run `terraform apply`: it looks your address up again and corrects the rule.

---

## Working on the code

**Tests** need nothing but a local Postgres:

```bash
cd app/backend && npm test                                           # unit
cd app/backend && DB_PASSWORD=<postgres password> npm run test:e2e   # its own tasksdb_e2e database
```

Running the whole stack on your own machine is a convenience, not part of the deployment, so it lives outside the repository — a `local/` directory with a `docker-compose.yml` and env templates, ignored by git. Nothing in `terraform/` or `gitops/` reads any of it, and the deployed system takes every value it needs from AWS Secrets Manager.

---

## Tech Stack

| | |
|---|---|
| **App** | Next.js (React) · NestJS · PostgreSQL · argon2id passwords · JWT sessions |
| **IaC** | Terraform — VPC, EKS, EC2, ECR, RDS, IAM |
| **Packaging** | Helm |
| **CI** | Jenkins + Trivy |
| **CD** | ArgoCD (GitOps, pull-based) |
| **Secrets** | External Secrets Operator + IRSA |
| **Ingress** | ingress-nginx |
| **Monitoring** | Prometheus · Grafana · Alertmanager |

## Database

Postgres runs on **RDS**, in private subnets, reachable only from the cluster.

- AWS creates and rotates the password. It never touches Terraform state or Git
- External Secrets Operator pulls it into the cluster
- The connection uses TLS with certificate verification
- The schema is created and upgraded by migrations the backend runs on startup — one replica at a time, under a database lock

Nothing to set up by hand.
