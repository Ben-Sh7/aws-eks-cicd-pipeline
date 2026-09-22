locals {
  cluster_autoscaler_service_account = "system:serviceaccount:kube-system:cluster-autoscaler"
}

data "aws_iam_policy_document" "cluster_autoscaler_assume_role" {
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
      values   = [local.cluster_autoscaler_service_account]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name_prefix        = "${local.project_name}-ca-"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/${aws_eks_cluster.main.name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name   = "${local.project_name}-cluster-autoscaler"
  role   = aws_iam_role.cluster_autoscaler.id
  policy = data.aws_iam_policy_document.cluster_autoscaler.json
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"
  timeout    = 600

  values = [yamlencode({
    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  })]

  depends_on = [
    aws_eks_node_group.main,
    helm_release.kube_prometheus_stack,
  ]
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_chart_version
  namespace  = "kube-system"
  timeout    = 600

  values = [yamlencode({
    autoDiscovery = {
      clusterName = aws_eks_cluster.main.name
    }

    awsRegion = var.aws_region

    rbac = {
      serviceAccount = {
        name = "cluster-autoscaler"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler.arn
        }
      }
    }

    extraArgs = {
      balance-similar-node-groups   = true
      skip-nodes-with-system-pods   = false
      skip-nodes-with-local-storage = false
      scale-down-unneeded-time      = var.scale_down_unneeded_time
      scale-down-delay-after-add    = var.scale_down_delay_after_add
      expander                      = "least-waste"
    }

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
  })]

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_openid_connect_provider.eks,
    helm_release.metrics_server,
  ]
}
