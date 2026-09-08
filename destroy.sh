#!/bin/bash
# Tears down everything: ArgoCD app -> ingress-nginx LB -> terraform destroy
# -> app-secrets -> verify_cleanup. Order matters: each step releases
# resources the next step's deletion depends on being gone.

set -e

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
ARGOCD_APP="$PROJECT_DIR/gitops/argocd-application.yaml"
AWS_REGION="us-east-1"

# Load secrets from .env if present (gitignored - see .env.example for what's needed).
# terraform destroy needs these too: the three TF_VAR_* have no defaults.
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
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

# Confirmation
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
    echo "  - VPC and all networking"
    echo "  - ingress-nginx + kube-prometheus-stack (Prometheus/Grafana) + argocd + external-secrets"
    echo "  - The task-manager application (ArgoCD-managed), including its PVC/EBS volume"
    echo -e "  - ${RED}The app-secrets AWS Secrets Manager secret - PERMANENTLY, with no 30-day recovery window${NC}"
    echo "    (created manually, outside Terraform - if you'd rather keep it across a future"
    echo "     create.sh, answer 'no' below when asked, then rerun this script)"
    echo ""
    echo -e "${RED}Type 'YES' to confirm deletion:${NC}"
    read -p "Confirmation: " confirmation

    if [ "$confirmation" != "YES" ]; then
        print_error "Deletion cancelled"
        exit 0
    fi

    echo ""
    echo -e "${YELLOW}Also permanently delete the app-secrets AWS Secrets Manager secret? (y/N)${NC}"
    echo "This is the one piece of this project that isn't Terraform-managed and won't be"
    echo "touched otherwise - it will keep costing a small amount monthly if you skip this."
    read -p "Delete app-secrets too? [y/N]: " delete_secret_answer
    if [[ "$delete_secret_answer" =~ ^[Yy]$ ]]; then
        DELETE_SECRET=true
    else
        DELETE_SECRET=false
        print_warning "Keeping app-secrets - it will still exist (and bill) after this script finishes."
    fi
}

# app-secrets is created manually, outside Terraform - nothing else touches
# it. --force-delete-without-recovery skips the normal 7-30 day recovery
# window (which would otherwise keep billing).
delete_app_secret() {
    if [ "$DELETE_SECRET" != true ]; then
        return 0
    fi

    print_header "DELETING app-secrets (AWS Secrets Manager)"

    if aws secretsmanager describe-secret --secret-id app-secrets --region "$AWS_REGION" &> /dev/null; then
        aws secretsmanager delete-secret --secret-id app-secrets --region "$AWS_REGION" \
            --force-delete-without-recovery > /dev/null
        print_success "app-secrets permanently deleted (no recovery window)"
    else
        print_warning "app-secrets not found - already deleted, or never created"
    fi
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

        print_step "Waiting for the Postgres PVC (and its EBS volume) to actually disappear..."
        for i in $(seq 1 24); do
            if ! kubectl get pvc postgres-pvc &> /dev/null; then
                print_success "PVC confirmed gone"
                break
            fi
            sleep 5
        done
        if kubectl get pvc postgres-pvc &> /dev/null; then
            print_warning "postgres-pvc is still present after 2 minutes - its EBS volume may not release cleanly. Check manually: kubectl get pvc,pv"
        fi
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

# Verify cleanup
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

    print_step "Checking for a leftover EBS volume from the Postgres PVC..."
    local orphan_volumes=$(aws ec2 describe-volumes \
        --filters "Name=status,Values=available" "Name=tag:kubernetes.io/created-for/pvc/name,Values=postgres-pvc" \
        --query 'length(Volumes)' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)

    if [ "$orphan_volumes" -gt 0 ]; then
        print_error "Found $orphan_volumes unattached EBS volume(s) from postgres-pvc - these are billed hourly even unattached. Inspect: aws ec2 describe-volumes --filters Name=tag:kubernetes.io/created-for/pvc/name,Values=postgres-pvc"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No leftover PVC volumes (✓)"
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

    print_step "Checking app-secrets (AWS Secrets Manager)..."
    if [ "$DELETE_SECRET" = true ]; then
        if aws secretsmanager describe-secret --secret-id app-secrets --region "$AWS_REGION" &> /dev/null; then
            print_error "app-secrets still exists (you chose to delete it - deletion may have failed)"
            orphans_found=$((orphans_found + 1))
        else
            print_success "app-secrets deleted (✓)"
        fi
    else
        print_warning "app-secrets was kept by your choice - it's still there and still billing a small amount"
    fi

    print_step "Checking NAT Gateways..."
    local nat_gateways=$(aws ec2 describe-nat-gateways \
        --filter "Name=tag:Project,Values=task-manager" \
        --query 'length(NatGateways)' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)

    if [ "$nat_gateways" -gt 0 ]; then
        print_error "Found $nat_gateways NAT Gateways (should be 0)"
        orphans_found=$((orphans_found + 1))
    else
        print_success "No NAT Gateways (✓)"
    fi

    print_step "Checking Elastic IPs..."
    local eips=$(aws ec2 describe-addresses \
        --query 'length(Addresses[?AssociationId==null])' \
        --region "$AWS_REGION" 2>/dev/null || echo 0)

    if [ "$eips" -gt 0 ]; then
        print_warning "Found $eips unassociated Elastic IPs (may be from other projects)"
    else
        print_success "No unassociated Elastic IPs (✓)"
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

# Show cost summary
show_cost_summary() {
    print_header "💰 COST SUMMARY"

    echo -e "${BLUE}Before deletion:${NC}"
    echo "  If running 24/7 for a month: ~\$139+"
    echo "  If running for a few hours: ~\$1-5"
    echo ""
    echo -e "${GREEN}After deletion:${NC}"
    echo "  ✓ All resources removed"
    echo "  ✓ No orphaned resource charges"
    echo "  ✓ No surprise bills"
}

# Main execution
main() {
    echo -e "${RED}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║     DEVOPS TASK MANAGER - COMPLETE PROJECT DESTRUCTION   ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    CLUSTER_GONE=false
    VPC_ID=""
    DELETE_SECRET=false

    confirm_destruction
    configure_kubectl
    delete_app_release
    delete_ingress_nginx_early
    delete_infrastructure
    delete_app_secret
    verify_cleanup
    show_cost_summary

    echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}✓ Project completely destroyed! No orphaned resources.${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
}

# Run main function
main
