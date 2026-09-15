# High Level Design

## The idea in one line

**Jenkins cannot touch the cluster.** It writes the new image tag to Git. ArgoCD reads Git and deploys.

That split is why a compromised CI server can't reach production, and why `git revert` is a rollback.

---

## Architecture

![task-manager AWS architecture: a commit becoming a running pod (1-7), and a user request reaching the database (A-E)](docs/architecture.png)

---

## Inside the cluster

Three EC2 instances:

| | Where | Why |
|---|---|---|
| **2 × worker nodes** | Private subnets, no public IP | Run the app. ASG 1–3, desired 2 |
| **1 × Jenkins** | Public subnet | Needs a public IP for GitHub webhooks. No cluster access |

The nodes need internet access to pull images. That goes out through one NAT gateway. ECR image layers skip it: they come from S3, through a free S3 gateway endpoint.

![Inside the cluster: browser to ingress to frontend to backend to database, every hop a ClusterIP Service](docs/inside-the-cluster.png)

### One way in

Browser → ingress → frontend → backend → database. Nothing skips a step.

- Both app Services are `ClusterIP`. No pod IP, no NodePort, no public IP
- `ingress-nginx` is the only `LoadBalancer`, so it's the only public entry point
- The ingress routes to the frontend only. The backend API is never exposed — the frontend forwards a fixed list of routes to it
- Worker nodes have no public IP, so a bad firewall rule can't expose them
- RDS accepts port 5432 from the nodes' security group only — not a CIDR, not the internet

**Replicas:** backend runs 3 (stateless, so it's cheap redundancy), frontend runs 1. Change the number in `values.yaml` and ArgoCD applies it on the next sync.

---

## The application

| | Tool | Job |
|---|---|---|
| **Frontend** | Next.js | Pages, plus a thin server layer (a *BFF*) that holds the session cookies and forwards API calls |
| **Backend** | NestJS | The API: accounts, sessions, tasks. Every route requires a valid access token unless marked public |
| **Database** | PostgreSQL | Schema managed by migrations the backend runs on startup |

### Sessions

1. The user signs up or signs in with a username and password. The backend checks the password against its **argon2id** hash
2. The backend issues an **access token** (a JWT, 15 minutes) and a **refresh token** (random, 7 days, stored only as a hash)
3. The frontend's server puts both in `httpOnly` cookies. Page JavaScript never sees a token, so an XSS bug cannot steal one
4. Every API call goes through the frontend, which adds the access token. When it expires, the frontend refreshes the pair
5. **A refresh token works once.** Presenting a rotated token again after a 30-second grace window counts as theft, and every session of that account ends

<details>
<summary>The other protections on the sign-in path</summary>

<br>

**Same answer for a wrong password and an unknown user** — same message, same hashing time. Neither reveals which usernames exist.

**Rate limits.** 20 attempts a minute per client on the sign-in, sign-up and refresh routes; 300 a minute elsewhere.

**Cross-site requests are rejected.** Cookies are `SameSite=Lax`, and every state-changing request must carry an `Origin` equal to `APP_URL`.

**Migrations cannot collide.** Three backend replicas start together; a Postgres advisory lock lets exactly one apply pending migrations while the others wait.

</details>

### Google sign-in: local environment only

Google sign-in is built in and works in the **local environment** — `npm run dev` or `docker compose`. **It is switched off in the AWS infrastructure.**

Google only redirects back to an **HTTPS** address on a **fixed domain**. The infrastructure serves plain HTTP on the ingress Load Balancer's generated name, which changes on every `create.sh` run.

**To make it work in the infrastructure, a domain is needed for HTTPS requests:**

| Needed | For |
|---|---|
| A domain, pointed at the ingress Load Balancer | A fixed address that survives every `create.sh` |
| A TLS certificate for that domain | HTTPS — Google refuses plain-HTTP redirect addresses |
| `https://<domain>/api/auth/callback` registered on the Google OAuth client | Google only returns users to registered addresses |
| `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` in Secrets Manager, delivered by External Secrets | Same path as the other secrets — never Git or Helm values |

Until then nothing Google-related is configured: without a client ID the backend refuses every Google token, and the login page hides the button.

---

## Key flows

**CI** — push → build → Trivy scan → push to ECR → bump the tag file → commit

**CD** — webhook → merge the values files → sync the chart → Kubernetes rolls out

**Secrets** — External Secrets Operator reads two secrets from Secrets Manager over IRSA and writes them into one K8s Secret: the RDS password, which AWS rotates itself and which never enters Terraform state or Git, and the JWT signing key, which Terraform generates.

<details>
<summary>Why ArgoCD ignores most commits — and reverts changes you never committed</summary>

<br>

ArgoCD compares **state**, not files. It renders the chart under `path: gitops/task-manager` and diffs the result against the live cluster.

Two consequences:

- A commit touching only `terraform/` or `app/` renders identical manifests. Nothing happens.
- A `kubectl edit` against the cluster matches no commit at all. `selfHeal` reverts it.

It acts on the difference, not on a file changing.

</details>

<details>
<summary>How deployment-specific values reach the chart without being committed</summary>

<br>

Six values can't live in Git: the RDS endpoint, the names of the RDS master secret and the JWT secret, the two ECR registry URLs, and the app's own address. They embed account-specific data or only exist after `terraform apply`.

The app's address is the ingress Load Balancer's DNS name. It changes on every run, and the frontend needs it as `APP_URL` to reject cross-site requests.

`create.sh` reads all six from `terraform output` and the cluster, and injects them into the ArgoCD Application as Helm parameters. The chart refuses to render if the JWT secret name or the app address is missing, so a gap shows up as a clear sync error rather than a broken app.

The chart itself stays generic. Deploying into a different AWS account needs no edit to it.

</details>

---

## Components

| Component | Tool | Job |
|---|---|---|
| Infra + add-ons | Terraform | VPC, EKS, EC2, ECR, RDS, and the four cluster add-ons |
| CI | Jenkins | Build, scan, push, bump the tag file |
| CD | ArgoCD | Apply the chart, self-heal drift, prune |
| App | Next.js + NestJS | Frontend with a session layer, and the API behind it |
| Database | RDS Postgres | Private, SG-restricted, AWS-managed password |
| Secrets | External Secrets Operator | Secrets Manager → K8s Secret |
| Packaging | Helm chart | Deployments, Services, ConfigMap, Secret, Ingress |
| Ingress | ingress-nginx | The single public entry point |
| Monitoring | kube-prometheus-stack | Prometheus, Grafana, Alertmanager |

---

## Alerting

`warning` and `critical` alerts go to Slack when `TF_VAR_slack_webhook_url` is set. Without it they still reach Alertmanager's UI.

Three things are silenced on purpose:

| Silenced | Why |
|---|---|
| `Watchdog` | Fires permanently by design — you alert on its *absence* |
| `InfoInhibitor` | Internal plumbing, never actionable |
| scheduler / controller-manager / etcd | EKS runs these on AWS's side and doesn't expose them |

**An alert that always fires is worse than no alert.** It teaches you to ignore the channel.

`kube-proxy` stays enabled — it genuinely runs here.

---

## Security

**Network**

| | |
|---|---|
| Worker nodes | Private subnets, no public IP. Egress via NAT, except in-region S3 (gateway endpoint) |
| App | HTTP through the ingress Load Balancer. The backend is `ClusterIP` only |
| Jenkins :8080 | Your IP + GitHub's webhook ranges. Nothing else |
| Jenkins SSH | **None.** Access is through SSM Session Manager |
| Grafana | ClusterIP. `port-forward` only |
| ArgoCD | ClusterIP, with one path exposed: `/api/webhook`, `pathType: Exact` |

**Identity**

| | |
|---|---|
| Jenkins | IAM instance profile, ECR push only. No static keys, no cluster access |
| External Secrets | IRSA, read-only, scoped to exactly two secret ARNs |
| RDS | Not public, encrypted, password created and rotated by AWS |
| App users | argon2id password hashes, rotating refresh tokens, `httpOnly` cookies |

**Both webhooks verify GitHub's HMAC signature.** Reaching the port isn't enough to trigger anything — so the firewall rules above are a second layer, not the only one.

<details>
<summary>Supply chain and runtime hardening</summary>

<br>

**Trivy gates the build.** HIGH and CRITICAL CVEs fail it before anything reaches ECR.

Trivy itself is pinned to a fixed version and checksum-verified, not pulled from a floating `latest`. Its own release pipeline was compromised twice in 2026 via poisoned releases.

**Runtime images** run a current Node LTS with `npm` removed from the final stage. npm's bundled dependencies were the last HIGH findings standing between the image and a clean scan. The compiled code is owned by root, so the process cannot modify it.

**Database connections use TLS with certificate verification** against the Amazon RDS CA bundle baked into the image. Not `rejectUnauthorized: false`, which encrypts without authenticating.

**Jenkins' apt key is pinned and its key id verified** before the repo is trusted. A key rotation fails the bootstrap loudly instead of silently installing from an unsigned source.

</details>

---

## Teardown

Order matters — each step frees something the next one needs gone.

1. Delete the ArgoCD Application *(cascades)*
2. Uninstall ingress-nginx, wait for its Load Balancer to disappear
3. Delete the monitoring PVCs
4. `terraform destroy` — RDS, NAT gateway and Elastic IP included
5. Sweep for orphaned EBS volumes
6. Delete the two GitHub webhooks
7. `verify_cleanup()` — check AWS directly for anything still billing

<details>
<summary>Why steps 5 and 6 exist</summary>

<br>

**Step 5 — the PVC deletion in step 3 isn't reliable.**

Deleting a PVC is asynchronous. The CSI driver only *then* calls AWS to delete the volume. But `terraform destroy` tears that driver down along with the cluster, so the call can be lost and the volumes survive — billed hourly, and invisible unless someone reads the output closely.

Step 5 sweeps up whatever is left, matching on the `Project` tag. It doesn't depend on the driver still being alive. This has caught volumes on every teardown so far.

**Step 6 — a leftover webhook leaks data.**

The Jenkins EC2's public IP goes back to AWS's pool and gets reassigned to another customer. A webhook left pointing at it would keep posting this repo's push payloads — commit messages, author names, email addresses — to a stranger's server.

</details>

See `destroy.sh` for the implementation.

---

## Known limitations

| Limitation | Trade-off |
|---|---|
| **No HTTPS** | Passwords and session cookies cross the internet in plain text, and cookies can't be `Secure`. Accepted for a practice project with no real users — fixing it needs a domain and a certificate |
| **Google sign-in works only in the local environment** | Making it work in the infrastructure needs a domain for HTTPS requests — see [Google sign-in](#google-sign-in-local-environment-only) |
| JWT signing key is in Terraform state | Like the Grafana and Jenkins passwords. State is local and gitignored; the RDS password is the one secret that never enters it |
| RDS is single-AZ | `multi_az = true` when uptime beats cost |
| One NAT gateway, not one per AZ | ~$32/month instead of ~$64. An AZ outage takes egress for both |
| S3 gateway endpoint only, no interface endpoints | ECR API, STS, Secrets Manager and EC2 calls still use the NAT. Interface endpoints cost ~$7/month each per AZ, more than the NAT |
| Helm add-ons install serially | Required — the provider shares one repo cache and concurrent installs fail |
| Alertmanager storage is `emptyDir` | Silences are lost on a pod restart. A ~1Gi PVC fixes it |
| No control-plane metrics | EKS doesn't expose them. They come from CloudWatch instead |
| No app-specific alerts | Current rules catch a crashed pod, not a backend returning 500s |
| ECR names don't match `project_name` | Intentional — those repos already hold image history |

---

## Jenkins bootstrap

`user_data` installs Jenkins, Docker and the AWS CLI on first boot. A Groovy script then runs as Jenkins starts and creates:

1. The admin account *(skipping the setup wizard, which would leave Jenkins with no login)*
2. The `github-credentials` credential
3. The `task-manager` pipeline job, wired to this repo

`create.sh` then points both webhooks at the new instance and starts the first build through the Jenkins API — ECR is empty after every run, and without a build the pods would wait for the next push.

---

## Deployment

```bash
cp .env.example .env   # fill in real values
./create.sh            # up — the app is live ~10 minutes after it finishes
./destroy.sh           # down
```
