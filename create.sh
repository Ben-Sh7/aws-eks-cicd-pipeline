#!/bin/bash
# Sets up infra + cluster add-ons via Terraform, then registers the app
# with ArgoCD. Usage: ./create.sh [--infra-only]

set -e  # Exit on any error

PROJECT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TERRAFORM_DIR="$PROJECT_DIR/terraform"
ARGOCD_APP="$PROJECT_DIR/gitops/argocd-application.yaml"

# Load secrets from .env if present (gitignored - see .env.example for what's needed).
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi

INFRA_ONLY=false
if [ "$1" == "--infra-only" ]; then
    INFRA_ONLY=true
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ============================================
# FUNCTIONS
# ============================================

print_header() {
    echo -e "\n${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║ $1${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}\n"
}

print_step() {
    echo -e "${YELLOW}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    print_header "CHECKING PREREQUISITES"

    local missing_tools=0

    # Check Terraform
    if ! command -v terraform &> /dev/null; then
        print_error "Terraform not installed"
        missing_tools=$((missing_tools + 1))
    else
        print_success "Terraform: $(terraform --version | head -1)"
    fi

    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not installed"
        missing_tools=$((missing_tools + 1))
    else
        print_success "AWS CLI: $(aws --version | head -1)"
    fi

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not installed"
        missing_tools=$((missing_tools + 1))
    else
        print_success "kubectl: $(kubectl version --client --short 2>/dev/null || echo 'installed')"
    fi

    # Check Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker not installed"
        missing_tools=$((missing_tools + 1))
    else
        print_success "Docker: $(docker --version)"
    fi

    # Check jq (used to parse the GitHub API responses when managing the webhook)
    if ! command -v jq &> /dev/null; then
        print_error "jq not installed"
        missing_tools=$((missing_tools + 1))
    else
        print_success "jq: $(jq --version)"
    fi

    if [ $missing_tools -gt 0 ]; then
        print_error "$missing_tools tools missing. Please install them first."
        exit 1
    fi

    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Run: aws configure"
        exit 1
    fi
    print_success "AWS credentials configured"

    # These fail closed in Terraform too, but check here first for a clearer message.
    if [ -z "$TF_VAR_grafana_admin_password" ]; then
        print_error "TF_VAR_grafana_admin_password is not set."
        print_error "Copy .env.example to .env, fill it in, and re-run (or export it directly)."
        exit 1
    fi
    if [ -z "$TF_VAR_jenkins_admin_password" ]; then
        print_error "TF_VAR_jenkins_admin_password is not set."
        print_error "Copy .env.example to .env, fill it in, and re-run (or export it directly)."
        exit 1
    fi
    if [ -z "$TF_VAR_github_pat" ]; then
        print_error "TF_VAR_github_pat is not set."
        print_error "Needs 'repo' and 'admin:repo_hook' scopes: https://github.com/settings/tokens"
        print_error "Copy .env.example to .env, fill it in, and re-run (or export it directly)."
        exit 1
    fi
    print_success "Grafana/Jenkins admin passwords and GitHub PAT are set"
}

create_infrastructure() {
    print_header "CREATING INFRASTRUCTURE WITH TERRAFORM"

    cd "$TERRAFORM_DIR"

    print_step "Initializing Terraform..."
    terraform init
    print_success "Terraform initialized"

    print_step "Planning deployment..."
    terraform plan -out=tfplan

    print_step "Applying infrastructure (~20-25 minutes: EKS + node group + Jenkins EC2 + ECR, then ingress-nginx + kube-prometheus-stack + argocd + external-secrets)..."
    terraform apply tfplan
    print_success "Infrastructure created"

    # Get outputs
    CLUSTER_NAME=$(terraform output -raw eks_cluster_name 2>/dev/null || echo "task-manager")
    JENKINS_IP=$(terraform output -raw jenkins_public_ip 2>/dev/null)
    BACKEND_REPO=$(terraform output -raw backend_repository_url 2>/dev/null)
    FRONTEND_REPO=$(terraform output -raw frontend_repository_url 2>/dev/null)
    AWS_REGION_OUT=$(terraform output -raw aws_region 2>/dev/null || echo "us-east-1")
    GITHUB_REPO=$(terraform output -raw github_repo 2>/dev/null || echo "Ben-Sh7/aws-eks-cicd-pipeline")

    cd "$PROJECT_DIR"
}

# Configure kubectl
configure_kubectl() {
    print_header "CONFIGURING KUBECTL"

    print_step "Updating kubeconfig..."
    aws eks update-kubeconfig --region "${AWS_REGION_OUT:-us-east-1}" --name "${CLUSTER_NAME:-task-manager}"
    print_success "kubeconfig updated"

    print_step "Verifying cluster connection..."
    kubectl cluster-info
    print_success "kubectl connected to EKS cluster"
}

# The EC2's public IP changes every time create.sh recreates it, so the
# webhook payload URL would go stale every cycle without this - creates the
# webhook if none exists, or repoints an existing one at the new IP.
configure_github_webhook() {
    print_header "CONFIGURING GITHUB WEBHOOK"

    local hook_url="http://${JENKINS_IP}:8080/github-webhook/"
    local api="https://api.github.com/repos/${GITHUB_REPO}/hooks"

    local existing_id
    existing_id=$(curl -s -H "Authorization: token $TF_VAR_github_pat" "$api" \
        | jq -r '.[] | select(.config.url // "" | test("github-webhook")) | .id' | head -1)

    if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
        print_step "Updating existing webhook (id $existing_id) to point at $hook_url..."
        curl -s -X PATCH -H "Authorization: token $TF_VAR_github_pat" "$api/$existing_id" \
            -d "{\"config\":{\"url\":\"$hook_url\",\"content_type\":\"json\"}}" > /dev/null
    else
        print_step "Creating webhook pointing at $hook_url..."
        curl -s -X POST -H "Authorization: token $TF_VAR_github_pat" "$api" \
            -d "{\"name\":\"web\",\"active\":true,\"events\":[\"push\"],\"config\":{\"url\":\"$hook_url\",\"content_type\":\"json\"}}" > /dev/null
    fi
    print_success "GitHub webhook configured"
}

register_argocd_app() {
    print_header "REGISTERING APP WITH ARGOCD (GitOps bootstrap)"

    print_step "Waiting for the ArgoCD Application CRD to be available..."
    for i in $(seq 1 30); do
        if kubectl get crd applications.argoproj.io &> /dev/null; then
            break
        fi
        sleep 10
    done

    kubectl apply -f "$ARGOCD_APP"
    print_success "ArgoCD Application 'task-manager' registered"
    print_step "ArgoCD will now sync gitops/task-manager from git automatically (initial sync may take a minute)."
}

# Get access information
get_access_info() {
    print_header "🎉 DEPLOYMENT COMPLETE - ACCESS INFORMATION"

    echo -e "${GREEN}Infrastructure:${NC}"
    echo "  EKS Cluster: ${CLUSTER_NAME:-task-manager}"
    echo "  Region: ${AWS_REGION_OUT:-us-east-1}"

    if [ ! -z "$JENKINS_IP" ]; then
        echo -e "\n${GREEN}Jenkins (CI only - builds+pushes images, no cluster access):${NC}"
        echo "  URL: http://$JENKINS_IP:8080  (user: admin, password: your TF_VAR_jenkins_admin_password)"
        echo "  The 'task-manager' Pipeline job and GitHub webhook are already configured."
    fi

    if [ ! -z "$BACKEND_REPO" ]; then
        echo -e "\n${GREEN}Docker Registries (ECR):${NC}"
        echo "  Backend: $BACKEND_REPO"
        echo "  Frontend: $FRONTEND_REPO"
    fi

    echo -e "\n${GREEN}Monitoring (Grafana - ClusterIP only, not public):${NC}"
    echo "  kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
    echo "  Then open http://localhost:3000  (user: admin, password: your TF_VAR_grafana_admin_password)"

    echo -e "\n${GREEN}CD (ArgoCD - ClusterIP only, not public):${NC}"
    echo "  kubectl port-forward -n argocd svc/argocd-server 8081:443"
    echo "  Then open https://localhost:8081  (user: admin, password:"
    echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

    echo -e "\n${GREEN}Ingress (app entrypoint):${NC}"
    echo "  kubectl get svc -n ingress-nginx ingress-nginx-controller   # find the external LoadBalancer hostname"

    echo -e "\n${GREEN}Kubernetes:${NC}"
    echo "  View pods: kubectl get pods"
    echo "  View logs: kubectl logs <pod-name>"
    echo "  View services: kubectl get svc"
    echo "  View ingress: kubectl get ingress"
    echo "  View ArgoCD sync status: kubectl get application -n argocd task-manager"

    if [ "$INFRA_ONLY" = true ]; then
        echo -e "\n${YELLOW}--infra-only was used: the app was NOT registered with ArgoCD.${NC}"
        echo "  Register it later with: kubectl apply -f gitops/argocd-application.yaml"
    fi

    echo -e "\n${YELLOW}One-time reminder:${NC} make sure the app-secrets AWS Secrets Manager secret exists"
    echo "  (external-secrets pulls DB_USER/DB_PASSWORD from it via IRSA):"
    echo "  aws secretsmanager create-secret --name app-secrets --region ${AWS_REGION_OUT:-us-east-1} \\"
    echo "    --secret-string '{\"DB_USER\":\"postgres\",\"DB_PASSWORD\":\"your-secure-password\"}'"

    echo -e "\n${GREEN}When you're done:${NC}"
    echo "  ./destroy.sh"

    echo -e "\n${GREEN}Cost tracking:${NC}"
    echo "  This infrastructure costs ~\$139+/month if left running 24/7"
    echo "  For a few hours of testing: ~\$2-5"
}

# Main execution
main() {
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║     DEVOPS TASK MANAGER - COMPLETE PROJECT SETUP         ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    check_prerequisites
    create_infrastructure
    configure_kubectl
    configure_github_webhook

    # Register the app with ArgoCD, unless --infra-only was passed
    if [ "$INFRA_ONLY" = false ]; then
        register_argocd_app
    fi

    # Show access information
    get_access_info

    echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Project is ready! Start building! 🚀${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
}

# Run main function
main "$@"
