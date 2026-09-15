# DevOps Task Manager

> Push code. Everything else — build, deploy, secrets, monitoring — happens by itself.

A task manager (Next.js + NestJS + PostgreSQL) on AWS EKS. GitOps CI/CD, all infrastructure as code.

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
# TF_VAR_slack_webhook_url=<url>       # optional — alerts to Slack
```

The other entries in `.env.example` are for [local development](#local-development) only.

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

`create.sh` also starts the first Jenkins build, because every run begins with an empty image registry. About 10 minutes after it finishes, the app is live at the `http://…elb.amazonaws.com` address it prints.

### What's generated for you

You supply two things, three with Slack. The rest is created automatically and kept in AWS Secrets Manager.

| You supply | Created for you |
|---|---|
| AWS profile | Grafana admin password |
| GitHub PAT | Jenkins admin password |
| Slack URL *(optional)* | Two webhook signing secrets |
| | JWT signing key for the app's sessions |
| | RDS password — created **and rotated** by AWS |

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

## Signing in

Open the app and **create an account with a username and password**.

- Passwords are stored as **argon2id** hashes — never the password itself
- A session is a 15-minute access token plus a refresh token that rotates on every use, both in `httpOnly` cookies the page's JavaScript cannot read
- Reusing an already-rotated refresh token counts as theft and ends every session of that account

> **The deployed app runs over plain HTTP.** Anyone on the network path can read passwords and session cookies. That is an accepted trade-off for a practice project with no real users — it needs a domain and a certificate to fix.

### Google sign-in: local environment only

Google sign-in works when you run the app locally — `npm run dev` or `docker compose` (see [Local development](#local-development)). **It is switched off in the AWS infrastructure**, where the login page shows only the username and password form.

**Why:** Google only redirects back to an **HTTPS** address on a **fixed domain**. The infrastructure serves plain HTTP on the Load Balancer's generated name, and that name changes on every `create.sh`.

**To make it work in the infrastructure, you need a domain for HTTPS requests:**

1. A domain you own, pointed at the ingress Load Balancer through DNS
2. A TLS certificate for that domain, so the app is served over HTTPS
3. `https://<your-domain>/api/auth/callback` registered as a redirect URI on the Google OAuth client
4. `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` delivered to the pods through Secrets Manager and External Secrets, like the other secrets

Until then the app needs no Google settings at all: without a client ID, the backend refuses every Google token and the button stays hidden.

---

## How It Works

```
git push → Jenkins builds & scans → ECR → Jenkins commits the tag → ArgoCD deploys
```

**1. You push.** A GitHub webhook fires.

**2. Jenkins builds and scans.** Trivy is a gate, not a report — a fixable HIGH or CRITICAL CVE fails the build and nothing reaches ECR.

**3. Jenkins writes the new tag to Git.** This is the handoff. Jenkins has no cluster access, so Git is how it tells ArgoCD what to deploy.

**4. ArgoCD deploys.** A second webhook wakes it, and it syncs the chart to EKS. The backend applies any new database migrations as it starts.

**5. Secrets arrive on their own.** External Secrets Operator pulls the DB credentials and the JWT signing key from Secrets Manager into the cluster. No secret ever passes through Git or Jenkins.

**6. Monitoring runs throughout.** Prometheus, Grafana, and Alertmanager. Set `TF_VAR_slack_webhook_url` and alerts go to Slack.

<details>
<summary>Details on the webhooks, the first build, alert filtering, and Jenkins' self-setup</summary>

<br>

**The webhooks are managed for you.** `create.sh` re-points them on every run, since the Jenkins IP changes each time.

**The first build starts itself.** ECR is recreated empty on every run, and a push is normally what starts a build — so `create.sh` starts one through the Jenkins API. If that fails, press **Build Now** in Jenkins.

**Jenkins skips its own commits.** A build started by a push whose last commit is the `ci: deploy` bump is skipped, so the pipeline cannot trigger itself forever. A build started by hand or by `create.sh` always runs.

**ArgoCD stays private.** Only its `/api/webhook` path is exposed through the ingress — the UI and API are not. Payloads must be signed with a secret Terraform generates. If the webhook is ever down, ArgoCD's own 180-second poll catches the change anyway.

**Alert noise is filtered.** `Watchdog` and `InfoInhibitor` are dropped. So are the chart's scheduler, controller-manager and etcd rules — EKS runs those on AWS's side where nothing can scrape them, so they'd report "down" forever.

**Jenkins configures itself.** No setup wizard. `terraform apply` runs a `user_data` script that installs Jenkins and Docker, plus a Groovy script that creates the admin login, the GitHub credential, and the pipeline job on first boot.

</details>

---

## Watching it happen

| | Where | How to get there |
|---|---|---|
| **The app** | `http://<elb-hostname>` | Printed by `create.sh`, or `kubectl get svc -n ingress-nginx` |
| **Jenkins** | `http://<ip>:8080` | Open from your IP — nobody else can reach it |
| **ArgoCD** | `https://localhost:8081` | `kubectl port-forward -n argocd svc/argocd-server 8081:443` |
| **Grafana** | `http://localhost:3000` | `kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80` |

`create.sh` prints these at the end, with the password lookups.

**Jenkins firewall:** port 8080 opens to your IP and GitHub's webhook ranges. Nothing else. There is no SSH — the box is reached through SSM Session Manager.

If your IP changes, re-run `create.sh`.

---

## Local development

**Everything in containers, as it runs in production:**

```bash
cp .env.example .env          # POSTGRES_PASSWORD and JWT_SECRET; Google is optional
docker compose up --build     # http://localhost:3000
```

**Day to day, with hot reload:** start only the database, then each app with its own env file.

```bash
docker compose up -d postgres-db
cd app/backend  && cp .env.example .env        && npm install && npm run start:dev   # :3001
cd app/frontend && cp .env.example .env.local  && npm install && npm run dev         # :3000
```

**Tests:**

```bash
cd app/backend && npm test                                  # unit
cd app/backend && DB_PASSWORD=<postgres password> npm run test:e2e   # against the local Postgres, in its own tasksdb_e2e database
```

To try Google sign-in locally, create an OAuth client of type *Web application* in Google Cloud Console with `http://localhost:3000/api/auth/callback` as a redirect URI, and put its ID and secret in the env files.

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
