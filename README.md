# DevOps Task Manager

> Push code. Everything else — build, deploy, secrets, monitoring — happens by itself.

A task manager (React + Node/Express + PostgreSQL) on AWS EKS. GitOps CI/CD, all infrastructure as code.

---

## Architecture

See **[HLD.md](HLD.md)** — diagrams, security design, and the reasoning behind each choice.

---

## Quick Start

**You need:** `terraform`, `aws`, `kubectl`, `docker`, `jq`, and AWS credentials.

**1. Create `.env`:**

```bash
AWS_PROFILE=<your AWS profile>         # skip if your creds are on [default]
TF_VAR_github_pat=<your GitHub PAT>    # see "GitHub token" below
POSTGRES_PASSWORD=<your password>      # local docker-compose only
# TF_VAR_slack_webhook_url=<url>       # optional — alerts to Slack
```

**2. Using SSO? Log in first.** Otherwise every AWS call fails.

```bash
aws sso login --profile <your AWS profile>
```

**3. Go.**

```bash
./create.sh     # ~25 min
./destroy.sh    # tears it all down
```

That's it. Both scripts read `.env` on their own.

### What's generated for you

You supply four things at most. The rest is created automatically and kept in AWS Secrets Manager.

| You supply | Created for you |
|---|---|
| AWS profile | Grafana admin password |
| GitHub PAT | Jenkins admin password |
| Postgres password *(local only)* | Two webhook signing secrets |
| Slack URL *(optional)* | RDS password — created **and rotated** by AWS |

Run `terraform output` to see where each one lives.

---

## GitHub token

You create this one by hand. Jenkins needs it to push, and `create.sh` needs it to manage webhooks.

1. Go to <https://github.com/settings/tokens> → **Tokens (classic)**
2. **Generate new token (classic)**
3. **Expiration:** 30 days. Not "never"
4. Tick two scopes: **`repo`** and **`admin:repo_hook`**
5. Copy the `ghp_...` string now — GitHub shows it once
6. Paste it into `.env`

> `create.sh` checks the token before building anything. A bad token fails in seconds, not 25 minutes in.

<details>
<summary>Why those two scopes, and using a fine-grained token</summary>

<br>

**`repo`** lets Jenkins clone the repo and push the `ci: deploy X` commit. That commit is how ArgoCD learns which image to run.

**`admin:repo_hook`** lets `create.sh` create and re-point the two webhooks. Without it the API returns 403 and a push triggers nothing.

**Fine-grained tokens** work too. Give it access to this repo with **Contents: Read and write** and **Webhooks: Read and write**. One caveat: they don't report their scopes over the API, so `create.sh` can only confirm the token is valid — not that it has enough permission.

</details>

---

## How It Works

```
git push → Jenkins builds & scans → ECR → Jenkins commits the tag → ArgoCD deploys
```

**1. You push.** A GitHub webhook fires.

**2. Jenkins builds and scans.** Trivy is a gate, not a report — a fixable HIGH or CRITICAL CVE fails the build and nothing reaches ECR.

**3. Jenkins writes the new tag to Git.** This is the handoff. Jenkins has no cluster access, so Git is how it tells ArgoCD what to deploy.

**4. ArgoCD deploys.** A second webhook wakes it, and it syncs the chart to EKS.

**5. Secrets arrive on their own.** External Secrets Operator pulls DB credentials from Secrets Manager into the cluster. No secret ever passes through Git or Jenkins.

**6. Monitoring runs throughout.** Prometheus, Grafana, and Alertmanager. Set `TF_VAR_slack_webhook_url` and alerts go to Slack.

<details>
<summary>Details on the webhooks, alert filtering, and Jenkins' self-setup</summary>

<br>

**The webhooks are managed for you.** `create.sh` re-points them on every run, since the Jenkins IP changes each time.

**ArgoCD stays private.** Only its `/api/webhook` path is exposed through the ingress — the UI and API are not. Payloads must be signed with a secret Terraform generates. If the webhook is ever down, ArgoCD's own 180-second poll catches the change anyway.

**Alert noise is filtered.** `Watchdog` and `InfoInhibitor` are dropped. So are the chart's scheduler, controller-manager and etcd rules — EKS runs those on AWS's side where nothing can scrape them, so they'd report "down" forever.

**Jenkins configures itself.** No setup wizard. `terraform apply` runs a `user_data` script that installs Jenkins and Docker, plus a Groovy script that creates the admin login, the GitHub credential, and the pipeline job on first boot.

</details>

---

## Watching it happen

| | Where | How to get there |
|---|---|---|
| **The app** | Public | `kubectl get svc -n ingress-nginx` |
| **Jenkins** | `http://<ip>:8080` | Open from your IP — nobody else can reach it |
| **ArgoCD** | `https://localhost:8081` | `kubectl port-forward -n argocd svc/argocd-server 8081:443` |
| **Grafana** | `http://localhost:3000` | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` |

`create.sh` prints these at the end, with the password lookups.

**Jenkins firewall:** port 8080 opens to your IP and GitHub's webhook ranges. Nothing else. There is no SSH — the box is reached through SSM Session Manager.

If your IP changes, re-run `create.sh`.

---

## Tech Stack

| | |
|---|---|
| **App** | React · Node/Express · PostgreSQL |
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

Nothing to set up by hand.
