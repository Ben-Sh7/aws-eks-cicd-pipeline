locals {
  trivy_namespace       = "trivy-system"
  trivy_service_account = "trivy-operator"

  trivy_values = {
    serviceAccount = {
      create      = true
      name        = local.trivy_service_account
      annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.trivy_operator.arn }
    }

    operator = {
      scanJobsConcurrentLimit       = 2
      scanJobTimeout                = "10m"
      configAuditScannerEnabled     = true
      exposedSecretScannerEnabled   = true
      rbacAssessmentScannerEnabled  = true
      infraAssessmentScannerEnabled = false
      clusterComplianceEnabled      = false
    }

    trivy = {
      severity      = "HIGH,CRITICAL"
      ignoreUnfixed = true

      resources = {
        requests = {
          cpu    = "100m"
          memory = "128Mi"
        }
        limits = {
          memory = "512Mi"
        }
      }
    }

    resources = {
      requests = {
        cpu    = "50m"
        memory = "128Mi"
      }
      limits = {
        memory = "256Mi"
      }
    }

    serviceMonitor = {
      enabled = true
    }
  }
}

data "aws_iam_policy_document" "trivy_operator_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url_no_scheme}:sub"
      values   = ["system:serviceaccount:${local.trivy_namespace}:${local.trivy_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "trivy_operator" {
  name_prefix        = "${local.project_name}-trivy-"
  assume_role_policy = data.aws_iam_policy_document.trivy_operator_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "trivy_operator_ecr_read" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
    ]
    resources = [
      aws_ecr_repository.backend.arn,
      aws_ecr_repository.frontend.arn,
    ]
  }
}

resource "aws_iam_role_policy" "trivy_operator_ecr_read" {
  name   = "${local.project_name}-trivy-ecr-read"
  role   = aws_iam_role.trivy_operator.id
  policy = data.aws_iam_policy_document.trivy_operator_ecr_read.json
}

resource "helm_release" "trivy_operator" {
  name             = "trivy-operator"
  repository       = "https://aquasecurity.github.io/helm-charts/"
  chart            = "trivy-operator"
  version          = var.trivy_operator_chart_version
  namespace        = local.trivy_namespace
  create_namespace = true
  timeout          = 600

  values = [yamlencode(local.trivy_values)]

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy.trivy_operator_ecr_read,
    helm_release.kube_prometheus_stack,
  ]
}
