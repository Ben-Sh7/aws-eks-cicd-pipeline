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

### Google sign-in

Google only returns users to an **HTTPS** address on a **fixed domain**, so both used to be blockers. The domain is now an input to the infrastructure rather than something it discovers afterwards, and TLS terminates on the load balancer with an ACM certificate, so the only thing left is the credential itself.

That credential belongs to a Google project, not to this infrastructure, so Terraform never holds it. It sits in the Secrets Manager entry maintained by hand, and Terraform only passes that entry's name to the chart:

| Step | Why |
|---|---|
| `https://app.<domain>/api/auth/callback` registered on the Google OAuth client | Google only returns users to registered addresses |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` in the credentials entry | The value reaches AWS without passing through Terraform, Git, or a local file |
| External Secrets syncs both into the cluster | Same path as every other secret |

`terraform output google_redirect_uri` and `credentials_secret` print what is needed. Leave the keys out and the backend refuses every Google token and the login page hides the button, while username + password sign-in works as usual.

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

Several values can't live in Git: the RDS endpoint, the names of the RDS master secret, the JWT secret and the Google credential, the two ECR registry URLs, and the app's own address. They embed account-specific data or are generated during the apply.

Terraform creates the ArgoCD `Application` itself — it travels with the ArgoCD Helm release, which puts it after the CRDs that define its kind — and passes all of them in as Helm parameters. They are ordinary Terraform references, so a mistake is a plan-time error rather than something that surfaces as a broken app.

The app's address is the one that used to be awkward: it was the ingress Load Balancer's generated DNS name, known only after the cluster was up and different on every rebuild, and the frontend needs it as `APP_URL` to reject cross-site requests. With a domain it is decided before anything is built, and the load balancer's hostname is just the target of a CNAME.

The chart refuses to render if the JWT secret name or the app address is missing, so a gap shows up as a clear sync error rather than a broken app.

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

`warning` and `critical` alerts go to Slack. The URL is never a Terraform input: External Secrets reads `SLACK_WEBHOOK_URL` out of the hand-maintained credentials entry, copies it into the monitoring namespace, and Alertmanager reads it from a mounted file (`api_url_file`) - so it reaches neither the state file nor a rendered Helm value. Without that key, alerts still reach Alertmanager's own UI.

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
| Two webhook signing secrets are in Terraform state | Unavoidable: Terraform hands the same value to GitHub and to the receiver, and an ephemeral value cannot reach an ordinary resource argument. Everything else it generates is written with a write-only argument and never recorded — see [State](#state) |
| The domain must already be a delegated Route53 zone | Terraform looks the zone up rather than creating it; a zone created in the same apply would not be delegated, and certificate validation would wait on DNS nobody can answer |
| A rebuild changes the Jenkins IP | The DNS record follows it, so the webhook keeps working, but the record's 60s TTL means a minute of stale answers |
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

The same Groovy script queues that job's first build — ECR is empty after every rebuild, and without one the pods would wait for the next push.

The three secrets it needs (its admin password, the webhook signing secret, and the GitHub token) are **not** rendered into `user_data`. Anything written there can be read back by every process on the instance through the metadata service, and is shown in plain text in the EC2 console. `user_data` carries only their Secrets Manager identifiers and fetches the values at boot with the instance's own IAM role, into files readable by the `jenkins` user alone.

Both webhooks are Terraform resources (`terraform/github.tf`) pointing at DNS names, so replacing the instance does not invalidate them.

---

## Deployment

```bash
cd terraform && terraform init && terraform apply   # up
./destroy.sh                                        # down, from the project root
```

One `terraform apply` builds everything, including DNS, the certificate, both GitHub webhooks and the first CI build. The app is live about ten minutes after it finishes, once that build has pushed images and ArgoCD has synced them.

There is no configuration file and no environment to set up. Three Secrets Manager entries - created once per account, outside the stack's lifecycle - carry the domain, the repository, the GitHub token and the Slack/Google credentials. Terraform reads the configuration ordinarily, reads the token through an `ephemeral` resource that it is not permitted to persist, and never reads the cluster's credentials at all: those go straight from AWS to the External Secrets operator. Nothing secret exists on the machine running the apply, which is also why `terraform destroy` needs no inputs.

### State

State is not a byproduct. It is the only record of what exists in the account, and it contains secrets, so it lives in S3 rather than next to the code: KMS-encrypted with a customer-managed key, versioned so a corrupted state is a restore rather than a rebuild, locked (S3 conditional writes - no DynamoDB table needed since Terraform 1.10) so two applies cannot overwrite each other, and with a bucket policy refusing anything that is not TLS. `terraform/bootstrap/` creates it; that configuration is the one place a local state file is acceptable, because it holds a bucket and a key and nothing else.

What is *in* the state is then a deliberate, short list. Secrets fall into three groups:

| | Where the value lives | How |
|---|---|---|
| RDS password | AWS only | `manage_master_user_password` - AWS creates and rotates it; Terraform never sees it |
| JWT key, Jenkins + Grafana admin | AWS only | Generated by an `ephemeral` resource and written with `secret_string_wo`, a write-only argument: sent to AWS, never recorded |
| Two webhook signing secrets | State (encrypted) | Terraform must hand the *same* value to GitHub and to the receiver, and both are ordinary resource arguments, which an ephemeral value may not reach |

The third row is the honest one. Zero secrets in state is not achievable when Terraform's job is to make two systems agree on a shared secret - which is why the professional answer is to protect state rather than to pretend it can be emptied.

Rotation of the second group is a single counter, `generated_secret_version`; incrementing it rewrites all three with fresh values.

Teardown keeps a script, because it is the asymmetric half: the load balancer and the EBS volumes are created by Kubernetes rather than by Terraform, so nothing in the state file knows they have to go first.
