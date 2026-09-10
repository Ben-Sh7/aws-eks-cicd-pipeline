# DevOps Task Manager — High Level Design

## Architecture

```mermaid
flowchart TD
    Dev([Developer]) -->|git push| GH[(GitHub repo)]
    GH -->|webhook| JK["Jenkins CI<br/>build → push → bump tag"]
    JK -->|docker push| ECR[(AWS ECR)]
    JK -->|commit values-images.yaml| GH
    GH -->|"webhook (poll every 180s as fallback)"| ARGO["ArgoCD CD<br/>sync Helm chart"]
    ARGO -->|deploys| EKS["EKS Cluster<br/>frontend / backend"]
    EKS -->|private subnet only| RDS[(RDS Postgres)]
    ASM[(AWS Secrets Manager)] -->|IRSA| ESO[External Secrets Operator]
    ESO -->|creates K8s Secret| EKS
    RDS -.->|AWS-managed master password| ASM
    EKS --> MON[Prometheus / Grafana]

    style GH fill:#24292e,color:#fff
    style ECR fill:#ff9900,color:#000
    style ASM fill:#ff9900,color:#000
    style RDS fill:#3b48cc,color:#fff
    style EKS fill:#326ce5,color:#fff
    style ARGO fill:#ef7b4d,color:#fff
    style JK fill:#d33833,color:#fff
```

## Inside the Cluster

Two EC2 instances back the EKS cluster as worker nodes (`t3.medium`, auto-scaling group sized 1-3, desired 2). Jenkins runs on a separate, third EC2 instance entirely outside the cluster - it never gets `kubectl`/cluster access at all (see Security).

```mermaid
flowchart TD
    User(["👤 User's browser"]) -->|"only public entry point"| ING["🌐 ingress-nginx<br/>type: LoadBalancer"]

    subgraph EKS["EKS Cluster — 2x EC2 worker nodes (t3.medium)"]
        direction TB
        FE["frontend-service · ClusterIP<br/>1 pod"]

        subgraph BESVC["backend-service · ClusterIP (load-balanced)"]
            direction LR
            BE1["backend pod #1"]
            BE2["backend pod #2"]
            BE3["backend pod #3"]
        end

        FE -->|"internal DNS name<br/>not reachable from outside"| BESVC
    end

    BE1 & BE2 & BE3 -->|"private subnet, SG-restricted"| DB[("RDS Postgres<br/>private subnets")]

    ING --> FE

    classDef public fill:#009639,color:#fff
    classDef internal fill:#1a73e8,color:#fff
    classDef db fill:#3b48cc,color:#fff
    classDef user fill:#555,color:#fff
    class ING public
    class FE,BE1,BE2,BE3 internal
    class DB db
    class User user
    style EKS fill:#0b1f3a,color:#fff,stroke:#326ce5,stroke-width:2px
    style BESVC fill:#0b1f3a,color:#fff,stroke:#1a73e8,stroke-width:1px
```

**Why this is locked down, not just "it works":** both app Services (`frontend-service`, `backend-service`) are `type: ClusterIP` - reachable only from inside the cluster's own network, with no direct pod IP, no NodePort, and no public IP. `ingress-nginx` is the *only* Service of type `LoadBalancer`, so it's the only thing with a public AWS ELB in front of it. RDS sits in private subnets with `publicly_accessible = false`, and its security group accepts port 5432 from the EKS nodes' security group only - not from a CIDR range, and not from the internet at all. Every request must enter through the ingress, which only forwards to `frontend-service`; the frontend calls the backend internally, and only the backend can reach the database.

**Replica counts and why:** backend runs 3 replicas (stateless, so scaling it is free and gives some redundancy); frontend runs 1 (a lightweight proxy layer, no state). These aren't fixed forever - `backend.replicaCount` etc. in `values.yaml` are just numbers ArgoCD applies on every sync.

## Key Flows

**CI (Jenkins):** push → build image → push to ECR → bump image tag in `values-images.yaml` → commit + push.

**CD (ArgoCD):** GitHub webhook (or the 180s reconciliation poll, whichever comes first) → merges `values.yaml` + `values-images.yaml` → syncs the Helm chart → Kubernetes rolls out the new pods.

ArgoCD compares *state*, not files: it renders the chart under `path: gitops/task-manager` and diffs the result against the live cluster. A commit that touches only `terraform/` or `app/` renders identical manifests and changes nothing. Equally, a change made directly against the cluster with `kubectl edit` matches no commit at all and is still reverted, because `selfHeal` acts on the diff rather than on a file event.

**Secrets (External Secrets Operator):** reads the RDS master secret - which AWS generates and rotates itself, so the password never enters Terraform state or git - from Secrets Manager via IRSA → creates/refreshes the `app-secret` K8s Secret → backend pods read it as `DB_USER`/`DB_PASSWORD`.

**Wiring the dynamic values:** the RDS endpoint, the name AWS gives its master secret, and the two ECR registry URLs (which embed the AWS account id) only exist after `terraform apply` and differ per deployment, so they can't be committed to git. `create.sh` reads them from `terraform output` and injects them into the ArgoCD Application as helm parameters, which keeps the chart itself fully generic - deploying into a different AWS account needs no edit to the chart.

## Components

| Component | Tool | Responsibility |
|---|---|---|
| Infra + cluster add-ons | Terraform | VPC/EKS/EC2/ECR/RDS + ingress-nginx, kube-prometheus-stack, argocd, external-secrets, EBS CSI driver |
| CI | Jenkins | Build, scan (Trivy), push image, bump the GitOps tag file |
| CD | ArgoCD | Applies the Helm chart, self-heals drift, prunes removed resources |
| Database | RDS Postgres | Private subnets, SG-restricted to the EKS nodes, AWS-managed master password |
| Secrets sync | External Secrets Operator | Syncs the RDS master secret from AWS Secrets Manager into a K8s Secret |
| App packaging | Helm chart (`gitops/task-manager`) | backend + frontend + configmap + secret/externalsecret + ingress |
| Ingress | ingress-nginx | Routes external traffic to the frontend |
| Monitoring | kube-prometheus-stack | Prometheus (15d retention) and Grafana on persistent volumes; Alertmanager runs with the chart defaults - on emptyDir, and routing to a null receiver |

## Security

- Jenkins: IAM instance profile scoped to ECR push only - no static AWS keys, no cluster access.
- External Secrets Operator: IRSA, read-only, scoped to the RDS master secret's exact ARN.
- RDS: private subnets, `publicly_accessible = false`, storage encrypted, port 5432 open only to the EKS nodes' security group. Master password generated and rotated by AWS - never in Terraform state.
- Grafana: ClusterIP only, reachable via `kubectl port-forward`.
- ArgoCD: ClusterIP, with exactly one path published through the ingress - `/api/webhook`, declared `pathType: Exact`, so the UI, `/api/v1`, and the gRPC endpoint are not routable from outside. Payloads must carry GitHub's HMAC signature over a Terraform-generated shared secret, so the open path cannot be used to force syncs. The UI stays `kubectl port-forward` only.
- Jenkins network exposure: port 8080 is reachable from GitHub's published webhook ranges (read at plan time from `api.github.com/meta`, so the rule follows GitHub) plus the single operator IP `create.sh` detects at run time. There is no SSH rule at all - the instance is reached through SSM Session Manager, which needs no inbound port. This matters because that host holds the GitHub PAT and ECR push rights.
- Jenkins itself: authenticated (single admin account), not left open on the setup wizard's default of no login. Its webhook endpoint verifies GitHub's HMAC signature over the payload, so reaching port 8080 is not by itself enough to start a build - the network restriction above is no longer the only thing in the way.
- Database connections: RDS runs with `rds.force_ssl=1` and the backend verifies the server certificate against the Amazon RDS CA bundle baked into its image, rather than the usual `rejectUnauthorized: false`, which encrypts without authenticating.
- Runtime images: built on a current Node LTS with `npm` left out of the runtime stage - `npm`'s own bundled dependencies were the last HIGH findings standing between the image and a clean Trivy scan.
- CI: Trivy scans both images for HIGH/CRITICAL CVEs and fails the build before anything reaches ECR - installed on the Jenkins EC2 pinned to a fixed, checksum-verified version, not a floating "latest" tag (Trivy's own release pipeline was compromised twice in 2026 via poisoned releases/tags).

## Cleanup Order

1. Delete the ArgoCD Application (cascades, releases everything it deployed)
2. Uninstall ingress-nginx, wait for its Load Balancer to release
3. Delete the monitoring PVCs - the Prometheus volume comes from a StatefulSet template and the Grafana one from the chart's persistence block, and neither `helm uninstall` nor `terraform destroy` removes them, so their EBS volumes would outlive the cluster and keep billing. Alertmanager has no PVC: its storage is left at the chart default, which is emptyDir
4. `terraform destroy` (RDS included - no final snapshot, so nothing is left to pay for)
5. Delete the two GitHub webhooks. The Jenkins EC2's public IP goes back to AWS's pool and is reassigned to another customer, so a webhook left behind would keep posting this repo's push payloads - commit messages, author names and emails - to a stranger's server
6. `verify_cleanup()` checks AWS directly for anything left over

See `destroy.sh` for the full script.

## Known Limitations

| Limitation | Mitigation |
|---|---|
| RDS is single-AZ, no read replica | `multi_az = true` when uptime matters more than cost |
| ECR repo names don't match `project_name` | Intentional - repos already hold image history |
| The four add-on Helm releases install one after another, not in parallel | Required: the Helm provider shares one repository cache across concurrent `helm_release` resources and all but one fail with "no cached repo found". Costs a few minutes per run |
| Alertmanager is deployed but has no receiver | The chart's default route points at a null receiver, so alerts are visible in its UI and go nowhere else. Wiring Slack or email is a values change, not an architectural one |
| Worker nodes sit in public subnets with public IPs | Their security group admits only the cluster's own SG and the ingress load balancer's SG - nothing from the internet. Private subnets would need a NAT gateway (~$32/month) for image pulls |

## Jenkins Bootstrap

`aws_instance.jenkins`'s `user_data` (see `terraform/templates/`) installs Jenkins/Docker/AWS CLI on first boot, then drops a Groovy script into `init.groovy.d/` that runs as Jenkins starts:
1. Creates a single admin account (skips the setup wizard, which would otherwise leave Jenkins with no login)
2. Creates the `github-credentials` credential from `github_pat`
3. Creates the `task-manager` Pipeline job (SCM = this repo, Script Path = `Jenkinsfile`, GitHub push trigger)

The Jenkins apt signing key is pinned *and* its key id is verified before the repository is trusted, so a key rotation on Jenkins' side fails the bootstrap loudly instead of silently installing from an unsigned repository.

`create.sh` then points the GitHub webhook at the new EC2's IP (re-pointing it every run, since the IP changes each time) and registers the second webhook that drives ArgoCD.

## Deployment

```bash
cp .env.example .env   # fill in real values - see comments in that file
./create.sh             # bring everything up
./destroy.sh            # tear everything down
```
