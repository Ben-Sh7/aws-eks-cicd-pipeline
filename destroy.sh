#!/bin/bash
# Tears down everything: ArgoCD app -> ingress-nginx LB -> monitoring PVCs
# -> terraform destroy -> verify_cleanup. Order matters: each step releases
# resources the next step's deletion depends on being gone.

set -e

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
ARGOCD_APP="$PROJECT_DIR/gitops/argocd-application.yaml"
AWS_REGION="us-east-1"
PROJECT_TAG="task-manager"

# Load secrets from .env if present (gitignored - see .env.example for what's needed).
# terraform destroy needs it too: github_pat has no default.
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${RED}╔════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║ $1${NC}"
    echo -e "${RED}╚════════════════════════════════════════════╝${NC}\n"
}

print_step() {
    echo -e "${YELLOW}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

confirm_destruction() {
    print_header "⚠️  DESTRUCTIVE ACTION - CONFIRMATION REQUIRED"

    echo -e "${RED}This will:${NC}"
    echo "  1. Delete the ArgoCD Application (cascades: deletes everything it deployed, releases its Load Balancer)"
    echo "  2. Delete all AWS resources via terraform destroy (EKS, EC2, ECR, VPC,"
    echo "     plus the ingress-nginx / kube-prometheus-stack / argocd / external-secrets Helm releases Terraform manages)"
    echo "  3. Cannot be undone!"
    echo ""
    echo -e "${YELLOW}Estimated resources to be deleted:${NC}"
    echo "  - EKS Cluster (task-manager)"
    echo "  - EC2 Instances (Jenkins)"
    echo "  - ECR Repositories (backend, frontend) - including their images"
    echo "  - VPC and all networking, including the NAT gateway and its Elastic IP"
    echo "  - ingress-nginx + kube-prometheus-stack (Prometheus/Grafana) + argocd + external-secrets"
    echo "  - The task-manager application (ArgoCD-managed)"
    echo -e "  - ${RED}The RDS Postgres instance and ALL its data - no final snapshot is taken${NC}"
    echo "    (its master secret is AWS-managed and is deleted along with the instance)"
    echo "  - Prometheus/Grafana persistent volumes (metrics history and saved dashboards)"
    echo ""
    echo -e "${RED}Type 'YES' to confirm deletion:${NC}"
    read -p "Confirmation: " confirmation

    if [ "$confirmation" != "YES" ]; then
        print_error "Deletion cancelled"
        exit 0
    fi
}

# The Prometheus PVC comes from a StatefulSet volumeClaimTemplate and the Grafana
# one from the chart's persistence block. Neither `helm uninstall` nor terraform
# destroy removes them, so their EBS volumes would survive the cluster and keep
# billing - this must run while the cluster still exists. (Alertmanager has no
# PVC; its storage is left at the chart default, emptyDir.)
delete_monitoring_pvcs() {
    print_header "DELETING MONITORING PERSISTENT VOLUMES"

    if [ "$CLUSTER_GONE" = true ]; then
        print_warning "Cluster already gone - skipping (check for stray EBS volumes in verify_cleanup below)."
        return 0
    fi

    if ! kubectl get namespace monitoring &> /dev/null; then
        print_warning "No monitoring namespace - nothing to delete"
        return 0
    fi

    local pvcs
    pvcs=$(kubectl get pvc -n monitoring -o name 2>/dev/null | wc -l)
    if [ "$pvcs" -eq 0 ]; then
        print_success "No PVCs in monitoring namespace"
        return 0
    fi

    print_step "Deleting $pvcs PVC(s) in the monitoring namespace..."
    kubectl delete pvc --all -n monitoring --timeout=120s || true

    print_step "Waiting for the backing EBS volumes to be released..."
    for i in $(seq 1 24); do
        if [ "$(kubectl get pvc -n monitoring -o name 2>/dev/null | wc -l)" -eq 0 ]; then
            print_success "Monitoring PVCs deleted - their EBS volumes were released"
            return 0
        fi
        sleep 5
    done
    print_warning "Some monitoring PVCs are still present - verify_cleanup will check for leftover EBS volumes."
}

configure_kubectl() {
    print_header "CONFIGURING KUBECTL"

    cd "$TERRAFORM_DIR"
    CLUSTER_NAME=$(terraform output -raw eks_cluster_name 2>/dev/null || echo "task-manager")
    VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "")
    cd "$PROJECT_DIR"

    if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &> /dev/null; then
        aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" > /dev/null
        print_success "kubectl configured for cluster: $CLUSTER_NAME"
    else
        print_warning "EKS cluster '$CLUSTER_NAME' not found - it may already be deleted. Skipping kubectl-based steps."
        CLUSTER_GONE=true
    fi
}

delete_app_release() {
    print_header "REMOVING APPLICATION (ArgoCD cascade delete)"

    if [ "$CLUSTER_GONE" = true ]; then
        print_warning "Cluster already gone - skipping"
        return 0
    fi

    if kubectl get application -n argocd task-manager &> /dev/null; then
        print_step "Deleting the task-manager ArgoCD Application (cascading)..."
        kubectl delete -f "$ARGOCD_APP" --wait=true --timeout=120s
        print_success "Application object deleted"
    else
        print_warning "No task-manager ArgoCD Application found - skipping (already removed, or never registered?)"
    fi
}

# Uninstalled here (not left to terraform destroy) so we can poll AWS
# until the ELB is actually gone before touching the VPC/security groups.
delete_ingress_nginx_early() {
    print_header "RELEASING INGRESS LOAD BALANCER"

    if [ "$CLUSTER_GONE" = true ]; then
        print_warning "Cluster already gone - skipping"
        return 0
    fi

    if ! command -v helm &> /dev/null; then
        print_warning "helm not installed - skipping the proactive uninstall. terraform destroy will still remove ingress-nginx, just without this script's extra pre-wait; watch for a possible DependencyViolation retry."
        return 0
    fi

    if ! helm status ingress-nginx -n ingress-nginx &> /dev/null; then
        print_warning "No ingress-nginx release found - skipping"
        return 0
    fi

    print_step "Uninstalling ingress-nginx (releases its Load Balancer)..."
    helm uninstall ingress-nginx -n ingress-nginx || true

    print_step "Waiting for its Load Balancer to actually disappear from AWS..."
    for i in $(seq 1 24); do
        local lb_count=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0)
        local clb_count=$(aws elb describe-load-balancers --region "$AWS_REGION" --query 'length(LoadBalancerDescriptions)' --output text 2>/dev/null || echo 0)
        if [ "$lb_count" -eq 0 ] && [ "$clb_count" -eq 0 ]; then
            print_success "Load Balancer confirmed released"
            return 0
        fi
        sleep 5
    done
    print_warning "A Load Balancer is still visible after 2 minutes - terraform destroy will likely still work (AWS eventual consistency), but check manually if it fails."
}

# Retried once on failure - a DependencyViolation from a stray ENI usually
# self-resolves within a minute.
delete_infrastructure() {
    print_header "DELETING TERRAFORM INFRASTRUCTURE"

    cd "$TERRAFORM_DIR"

    print_step "Planning destruction..."
    terraform plan -destroy -out=destroy.tfplan

    print_step "Destroying infrastructure..."
    print_warning "This may take 15-20 minutes (Helm add-ons, then EKS cluster deletion)..."

    if ! terraform apply destroy.tfplan; then
        print_warning "terraform destroy failed - this is often a transient DependencyViolation (AWS still releasing an ENI/ELB). Waiting 60s and retrying once..."
        sleep 60
        terraform plan -destroy -out=destroy.tfplan
        terraform apply destroy.tfplan
    fi
    print_success "Infrastructure destroyed"

    cd "$PROJECT_DIR"
}

# The Jenkins EC2's public IP returns to AWS's pool and gets handed to another
# customer; the load balancer hostname stops resolving. A webhook left pointing
# at either keeps delivering this repo's push payloads - commit messages, author
# names and email addresses - to whoever holds that address next. Only the two
# hooks this project creates are touched; anything else on the repo is left
# alone.
# delete_monitoring_pvcs waits for the PVC objects to disappear and treats that
# as the volumes being gone, but PV deletion is asynchronous: the CSI driver
# only then calls DeleteVolume against AWS. terraform destroy tears that driver
# down along with the cluster, so the call can be lost and the EBS volumes
# survive - billed hourly, and easy to miss. This sweep runs after terraform and
# deletes what is provably left over: volumes that are unattached AND tagged as
# belonging to this project.
delete_orphaned_volumes() {
    print_header "SWEEPING UP ORPHANED EBS VOLUMES"

    local vols
    vols=$(aws ec2 describe-volumes \
        --filters "Name=status,Values=available" "Name=tag:Project,Values=${PROJECT_TAG}" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr -d '\015' || true)

    if [ -z "$vols" ] || [ "$vols" = "None" ]; then
        print_success "No orphaned EBS volumes"
        return 0
    fi

    local v
    for v in $vols; do
        if aws ec2 delete-volume --volume-id "$v" > /dev/null 2>&1; then
            print_success "Deleted orphaned volume $v"
        else
            print_warning "Could not delete $v - remove it by hand, it is billed hourly."
        fi
    done
}

delete_github_webhooks() {
    print_header "REMOVING GITHUB WEBHOOKS"

    if [ -z "$TF_VAR_github_pat" ]; then
        print_warning "TF_VAR_github_pat is not set - the webhooks are still in place."
        print_warning "Delete them under Settings -> Webhooks; they now point at addresses you no longer own."
        return 0
    fi

    if ! command -v jq &> /dev/null; then
        print_warning "jq is not installed - cannot read the webhook list, leaving them in place."
        return 0
    fi

    local repo
    repo=$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null         | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##' || true)

    if [ -z "$repo" ]; then
        print_warning "Could not determine the GitHub repo from the git remote - skipping."
        return 0
    fi

    local api="https://api.github.com/repos/${repo}/hooks"
    local ids
    # tr -d '\015': jq.exe on Windows emits CRLF, and a trailing carriage return
    # in the id produces a malformed URL that curl rejects with exit 3 - which
    # under set -e killed this function silently, before verify_cleanup ran.
    ids=$(curl -s -H "Authorization: token $TF_VAR_github_pat" "$api"         | jq -r '.[] | select(.config.url // "" | test("github-webhook|/api/webhook")) | .id' 2>/dev/null         | tr -d '\015' || true)

    if [ -z "$ids" ]; then
        print_success "No project webhooks left on $repo"
        return 0
    fi

    local id status
    for id in $ids; do
        # || echo "000": a curl that cannot even build the request exits non-zero,
        # and an unguarded assignment under set -e aborts the whole teardown.
        status=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE             -H "Authorization: token $TF_VAR_github_pat" "$api/$id" || true)
        if [ "$status" = "204" ]; then
            print_success "Deleted webhook $id"
        else
            print_warning "Could not delete webhook $id (HTTP $status) - remove it by hand."
        fi
    done
}

verify_cleanup() {
    print_header "VERIFYING CLEANUP - CHECKING FOR ORPHANED RESOURCES"

    local orphans_found=0

    print_step "Checking EC2 instances..."
    local ec2_count=$(aws ec2 describe-instances \
        --filters "Name=tag:Project,Values=task-manager" "Name=instance-state-name,Values=running,stopped" \
        --query 'length(Reservations[].Instances[])' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)

    if [ "$ec2_count" -gt 0 ]; then
        print_error "Found $ec2_count EC2 instances (should be 0)"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No EC2 instances (✓)"
    fi

    print_step "Checking EKS clusters..."
    local eks_clusters=$(aws eks list-clusters --region "$AWS_REGION" --query 'clusters[?contains(@, `task-manager`)]' --output text)

    if [ ! -z "$eks_clusters" ]; then
        print_error "Found EKS cluster: $eks_clusters (should be empty)"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No EKS clusters (✓)"
    fi

    print_step "Checking VPCs..."
    local vpcs=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Project,Values=task-manager" \
        --query 'length(Vpcs)' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)

    if [ "$vpcs" -gt 0 ]; then
        print_error "Found $vpcs VPCs (should be 0)"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No VPCs (✓)"
    fi

    if [ ! -z "$VPC_ID" ]; then
        print_step "Checking for leftover ENIs in this project's VPC..."
        local eni_count=$(aws ec2 describe-network-interfaces \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query 'length(NetworkInterfaces)' \
            --region "$AWS_REGION" 2>/dev/null || echo 0)

        if [ "$eni_count" -gt 0 ]; then
            print_error "Found $eni_count leftover ENI(s) in VPC $VPC_ID - this can block security-group/VPC deletion. Inspect: aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$VPC_ID"
            orphans_found=$((orphans_found + 1))
        else
            print_success "No leftover ENIs (✓)"
        fi
    fi

    # Covers every dynamically-provisioned volume (Prometheus, Grafana) -
    # the gp3-tagged StorageClass stamps them all with Project=task-manager.
    print_step "Checking for leftover EBS volumes..."
    local orphan_volumes=$(aws ec2 describe-volumes \
        --filters "Name=status,Values=available" "Name=tag:Project,Values=task-manager" \
        --query 'length(Volumes)' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)

    if [ "$orphan_volumes" -gt 0 ]; then
        print_error "Found $orphan_volumes unattached EBS volume(s) - these are billed hourly even unattached. Inspect: aws ec2 describe-volumes --filters Name=status,Values=available Name=tag:Project,Values=task-manager"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No leftover EBS volumes (✓)"
    fi

    print_step "Checking ECR repositories..."
    local ecr_repos=$(aws ecr describe-repositories \
        --region "$AWS_REGION" \
        --query "repositories[?repositoryName contains 'devops-task-manager']" \
        --output text 2>/dev/null)

    if [ ! -z "$ecr_repos" ]; then
        print_error "Found ECR repositories still present (should be 0 - terraform destroy may not have completed for them)"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No ECR repositories (✓)"
    fi

    print_step "Checking RDS instances..."
    if aws rds describe-db-instances --db-instance-identifier task-manager-postgres --region "$AWS_REGION" &> /dev/null; then
        print_error "RDS instance 'task-manager-postgres' still exists - this is the most expensive resource here"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No RDS instance (✓)"
    fi

    # skip_final_snapshot is set, so there should be none - but a snapshot
    # outlives its instance and keeps billing for storage.
    print_step "Checking RDS snapshots..."
    local rds_snapshots=$(aws rds describe-db-snapshots \
        --db-instance-identifier task-manager-postgres \
        --query 'length(DBSnapshots)' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)

    if [ "$rds_snapshots" -gt 0 ]; then
        print_error "Found $rds_snapshots RDS snapshot(s) - these bill for storage. Inspect: aws rds describe-db-snapshots --db-instance-identifier task-manager-postgres"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No RDS snapshots (✓)"
    fi

    # A NAT gateway bills ~$0.045/hr until its state reaches "deleted". "deleted"
    # and "failed" ones are free and linger in the API for ~1h, so exclude them.
    print_step "Checking NAT Gateways..."
    local nat_gateways=$(aws ec2 describe-nat-gateways \
        --filter "Name=tag:Project,Values=task-manager" "Name=state,Values=pending,available,deleting" \
        --query 'length(NatGateways)' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)

    if [ "$nat_gateways" -gt 0 ]; then
        print_error "Found $nat_gateways live NAT Gateway(s) - billed hourly. Inspect: aws ec2 describe-nat-gateways --filter Name=tag:Project,Values=task-manager"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No live NAT Gateways (✓)"
    fi

    # The NAT gateway's Elastic IP. If terraform removed the NAT gateway but the
    # EIP release failed, it sits unassociated and bills ~$0.005/hr while held.
    print_step "Checking this project's Elastic IPs..."
    local project_eips=$(aws ec2 describe-addresses \
        --filters "Name=tag:Project,Values=task-manager" \
        --query 'length(Addresses[?AssociationId==null])' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)

    if [ "$project_eips" -gt 0 ]; then
        print_error "Found $project_eips unassociated task-manager Elastic IP(s) - billed hourly. Release: aws ec2 release-address --allocation-id <id> (list: aws ec2 describe-addresses --filters Name=tag:Project,Values=task-manager)"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No orphaned project Elastic IPs (✓)"
    fi

    local other_eips=$(aws ec2 describe-addresses \
        --query 'length(Addresses[?AssociationId==null])' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)
    if [ "$other_eips" -gt 0 ]; then
        print_warning "$other_eips unassociated Elastic IP(s) exist account-wide (may be other projects - not touched)"
    fi

    print_step "Checking Elastic/Classic Load Balancers..."
    local elbv2_count=$(aws elbv2 describe-load-balancers \
        --query 'length(LoadBalancers)' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)
    local elb_classic_count=$(aws elb describe-load-balancers \
        --query 'length(LoadBalancerDescriptions)' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)

    if [ "$elbv2_count" -gt 0 ] || [ "$elb_classic_count" -gt 0 ]; then
        print_error "Found $elbv2_count ALB/NLB + $elb_classic_count Classic ELB - inspect manually, these may be leftovers from a Kubernetes Service/Ingress"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No Load Balancers (✓)"
    fi

    # Secrets bill while pending deletion. Ours use recovery_window_in_days = 0,
    # and AWS deletes the RDS-managed secret along with the DB instance.
    print_step "Checking Secrets Manager secrets..."
    local secrets_left=$(aws secretsmanager list-secrets \
        --query "length(SecretList[?starts_with(Name, 'task-manager/')])" \
        --region "$AWS_REGION" 2>/dev/null || echo 0)

    if [ "$secrets_left" -gt 0 ]; then
        print_error "Found $secrets_left project secret(s) still present - they bill even while pending deletion. Inspect: aws secretsmanager list-secrets --query \"SecretList[?starts_with(Name, 'task-manager/')].Name\""
        orphans_found=$((orphans_found + 1))
    else
        print_success "No project secrets (✓)"
    fi

    echo ""
    if [ $orphans_found -eq 0 ]; then
        print_success "✓ CLEANUP VERIFIED - NO ORPHANED RESOURCES!"
        return 0
    else
        print_error "⚠ Found $orphans_found resource(s) that should have been deleted"
        print_warning "Please check AWS Console and delete manually if needed"
        return 1
    fi
}

show_cost_summary() {
    print_header "💰 COST SUMMARY"

    echo -e "${BLUE}Before deletion:${NC}"
    echo "  If running 24/7 for a month: ~\$170+ (incl. ~\$32 NAT gateway)"
    echo "  If running for a few hours: ~\$3-6"
    echo ""
    echo -e "${GREEN}After deletion:${NC}"
    echo "  ✓ All resources removed"
    echo "  ✓ No orphaned resource charges"
    echo "  ✓ No surprise bills"
}

main() {
    echo -e "${RED}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║     DEVOPS TASK MANAGER - COMPLETE PROJECT DESTRUCTION   ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    CLUSTER_GONE=false
    VPC_ID=""

    confirm_destruction
    configure_kubectl
    delete_app_release
    delete_ingress_nginx_early
    delete_monitoring_pvcs
    delete_infrastructure
    delete_orphaned_volumes
    delete_github_webhooks
    verify_cleanup
    show_cost_summary

    echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Project completely destroyed! No orphaned resources.${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
}

main
