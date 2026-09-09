terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# Kubernetes/Helm provider auth. The token is fetched through the exec plugin
# rather than data.aws_eks_cluster_auth: that data source is resolved once per
# plan and stored in state, so on the next run Terraform configures the provider
# with a token minted hours earlier - EKS tokens live 15 minutes, and the
# refresh then fails with a bare "Unauthorized". exec mints one per call.
# The aws CLI this needs is already a hard prerequisite of create.sh.
locals {
  eks_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name, "--region", var.aws_region]
  }
}

provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

  exec {
    api_version = local.eks_exec.api_version
    command     = local.eks_exec.command
    args        = local.eks_exec.args
  }
}

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

    exec {
      api_version = local.eks_exec.api_version
      command     = local.eks_exec.command
      args        = local.eks_exec.args
    }
  }
}

locals {
  project_name = var.project_name
  environment  = var.environment

  # Hardcoded, not derived from project_name - these repos already hold
  # real image history and must not be renamed/recreated.
  ecr_backend_repo_name  = "devops-task-manager-backend"
  ecr_frontend_repo_name = "devops-task-manager-frontend"

  common_tags = {
    Project     = local.project_name
    Environment = local.environment
    CreatedBy   = "Terraform"
    # No CreatedDate here: timestamp() is unknown at plan time, which turned
    # every tagged resource into a phantom in-place update on every run and
    # forced the (immutable) gp3-tagged StorageClass to be replaced each time.
    ManagedBy = "IaC"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-vpc" }
  )
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-igw" }
  )
}

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_1_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-public-subnet-1" }
  )
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_2_cidr
  availability_zone       = "${var.aws_region}b"
  map_public_ip_on_launch = true

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-public-subnet-2" }
  )
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-public-rt" }
  )
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "eks" {
  name_prefix = "${local.project_name}-eks-"
  description = "Security group for EKS cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-eks-sg" }
  )
}

# GitHub publishes the source ranges its webhooks are delivered from. Reading
# them here keeps the Jenkins ingress rule correct without pinning a list that
# silently goes stale - if this endpoint is unreachable the plan fails loudly
# rather than falling back to 0.0.0.0/0.
data "http" "github_meta" {
  url = "https://api.github.com/meta"
  request_headers = {
    Accept = "application/vnd.github+json"
  }
}

locals {
  github_hook_cidrs = [
    for c in jsondecode(data.http.github_meta.response_body).hooks : c
    if !strcontains(c, ":")
  ]
}

resource "aws_security_group" "jenkins" {
  name_prefix = "${local.project_name}-jenkins-"
  description = "Security group for Jenkins EC2 instance"
  vpc_id      = aws_vpc.main.id

  # GitHub has to reach /github-webhook/ to trigger builds, so 8080 cannot be
  # closed outright - but it does not need to be open to the internet either.
  # These are GitHub's own published hook source ranges, read at plan time.
  ingress {
    description = "Jenkins webhook endpoint - GitHub published hook ranges"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = local.github_hook_cidrs
  }

  # Human access to the Jenkins UI. create.sh fills this with the public IP it
  # is running from; empty means nobody but GitHub can reach 8080.
  dynamic "ingress" {
    for_each = length(var.jenkins_ui_allowed_cidrs) > 0 ? [1] : []
    content {
      description = "Jenkins web UI, operator access only"
      from_port   = 8080
      to_port     = 8080
      protocol    = "tcp"
      cidr_blocks = var.jenkins_ui_allowed_cidrs
    }
  }

  # No SSH rule on purpose. The instance is reached through SSM Session Manager
  # (see the AmazonSSMManagedInstanceCore attachment in jenkins.tf), which needs
  # no inbound port at all - port 22 open to 0.0.0.0/0 on a host holding the
  # GitHub PAT and ECR push rights was the single largest hole here.

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-jenkins-sg" }
  )
}

resource "aws_iam_role" "eks_cluster_role" {
  name_prefix = "${local.project_name}-eks-cluster-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_iam_role" "eks_node_role" {
  name_prefix = "${local.project_name}-eks-node-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_eks_cluster" "main" {
  name     = local.project_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = [aws_subnet.public_1.id, aws_subnet.public_2.id]
    security_group_ids      = [aws_security_group.eks.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-cluster" }
  )
}

# A node group's own `tags` only tag the EKS node group object - they do NOT
# reach the EC2 instances or their volumes. A launch template with
# tag_specifications is the only way to tag those, and verify_cleanup in
# destroy.sh looks for orphans by the Project tag, so this is required.
resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${local.project_name}-nodes-"

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.common_tags,
      { Name = "${local.project_name}-node" }
    )
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(
      local.common_tags,
      { Name = "${local.project_name}-node-volume" }
    )
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.project_name}-nodes"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [aws_subnet.public_1.id, aws_subnet.public_2.id]
  version         = var.kubernetes_version

  scaling_config {
    desired_size = var.node_desired_size
    max_size     = var.node_max_size
    min_size     = var.node_min_size
  }

  instance_types = [var.node_instance_type]

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-nodes" }
  )

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_registry_policy
  ]
}

resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.jenkins_instance_type
  subnet_id              = aws_subnet.public_1.id
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name

  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.jenkins_root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    tags = merge(
      local.common_tags,
      { Name = "${local.project_name}-jenkins-root" }
    )
  }

  user_data = templatefile("${path.module}/templates/jenkins-user-data.sh.tftpl", {
    groovy_script = local.jenkins_groovy_script
  })

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-jenkins" }
  )
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_ecr_repository" "backend" {
  name                 = local.ecr_backend_repo_name
  image_tag_mutability = "MUTABLE"
  # Without this, terraform destroy fails on a non-empty repo.
  force_delete = true
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(
    local.common_tags,
    { Name = "${local.ecr_backend_repo_name}-repo" }
  )
}

resource "aws_ecr_repository" "frontend" {
  name                 = local.ecr_frontend_repo_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(
    local.common_tags,
    { Name = "${local.ecr_frontend_repo_name}-repo" }
  )
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "frontend" {
  repository = aws_ecr_repository.frontend.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
