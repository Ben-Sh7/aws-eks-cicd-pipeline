locals {
  lb_controller_service_account = "aws-load-balancer-controller"

  # One ALB serves the app, Jenkins and the ArgoCD webhook: every Ingress that
  # names this group joins it. Settings that belong to the load balancer itself
  # must agree across the group, so all three take them from here.
  alb_group = local.project_name

  alb_group_annotations = {
    "alb.ingress.kubernetes.io/group.name"               = local.alb_group
    "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
    "alb.ingress.kubernetes.io/target-type"              = "ip"
    "alb.ingress.kubernetes.io/listen-ports"             = jsonencode([{ HTTP = 80 }, { HTTPS = 443 }])
    "alb.ingress.kubernetes.io/ssl-redirect"             = "443"
    "alb.ingress.kubernetes.io/certificate-arn"          = aws_acm_certificate_validation.main.certificate_arn
    "alb.ingress.kubernetes.io/ssl-policy"               = local.alb_ssl_policy
    "alb.ingress.kubernetes.io/wafv2-acl-arn"            = aws_wafv2_web_acl.main.arn
    "alb.ingress.kubernetes.io/load-balancer-attributes" = "routing.http.drop_invalid_header_fields.enabled=true"
    "alb.ingress.kubernetes.io/target-group-attributes"  = "deregistration_delay.timeout_seconds=30"
  }

  # TLS 1.3 and 1.2; 1.0 and 1.1 are refused.
  alb_ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  # The ALB lives in the public subnets and connects to pods from there, so
  # these are the only addresses the frontend's NetworkPolicy lets in.
  alb_subnet_cidrs = [var.public_subnet_1_cidr, var.public_subnet_2_cidr]
}

data "aws_iam_policy_document" "lb_controller_assume_role" {
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
      values   = ["system:serviceaccount:kube-system:${local.lb_controller_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lb_controller" {
  name_prefix        = "${local.project_name}-lbc-"
  assume_role_policy = data.aws_iam_policy_document.lb_controller_assume_role.json
  tags               = local.common_tags
}

# The policy AWS publishes for this controller version, unchanged. Its write
# actions are limited to resources carrying the controller's own cluster tag.
resource "aws_iam_role_policy" "lb_controller" {
  name   = "${local.project_name}-lbc"
  role   = aws_iam_role.lb_controller.id
  policy = file("${path.module}/policies/aws-load-balancer-controller-iam-policy.json")
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_load_balancer_controller_chart_version
  namespace  = "kube-system"
  timeout    = 600

  values = [yamlencode({
    clusterName  = aws_eks_cluster.main.name
    region       = var.aws_region
    vpcId        = aws_vpc.main.id
    replicaCount = 2

    serviceAccount = {
      create = true
      name   = local.lb_controller_service_account
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.lb_controller.arn
      }
    }

    # Every load balancer, target group and security group it creates carries
    # the stack's tags, so the leftover check after a destroy sees them.
    defaultTags = local.common_tags

    # The Service webhook rewrites LoadBalancer Services into NLBs. Nothing here
    # uses that, and with failurePolicy Fail it refuses every Service in the
    # cluster whenever the controller is not running.
    enableServiceMutatorWebhook = false

    # Classic WAF and Shield Advanced are not used; WAFv2 is.
    enableWaf    = false
    enableShield = false

    podDisruptionBudget = { maxUnavailable = 1 }

    topologySpreadConstraints = [
      for spread in [
        { key = "kubernetes.io/hostname", when = "DoNotSchedule" },
        { key = "topology.kubernetes.io/zone", when = "ScheduleAnyway" },
        ] : {
        maxSkew           = 1
        topologyKey       = spread.key
        whenUnsatisfiable = spread.when
        nodeTaintsPolicy  = "Honor"
        labelSelector = {
          matchLabels = {
            "app.kubernetes.io/name"     = "aws-load-balancer-controller"
            "app.kubernetes.io/instance" = "aws-load-balancer-controller"
          }
        }
        matchLabelKeys = ["pod-template-hash"]
      }
    ]

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }

    serviceMonitor = {
      enabled = true
    }
  })]

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy.lb_controller,
    helm_release.prometheus_operator_crds,
  ]
}

# The ALB is made by the controller, not by Terraform, so Terraform cannot wait
# for it to go. The ArgoCD Application and the webhook Ingress depend on this
# gate, and the gate on the controller and ArgoCD: on destroy, those two go
# first, then this waits until the controller has deleted the ALB, its target
# groups and its security groups - while the controller and ArgoCD (which deletes
# the app's own Ingress) are still running. Jenkins depends on the controller
# directly, so it installs without waiting for ArgoCD; its Ingress goes while
# this waits, and the controller cannot go before both. Without the gate, the
# ALB outlives its controller and nothing would ever delete it.
resource "terraform_data" "load_balancer_cleanup_gate" {
  input = {
    cluster = aws_eks_cluster.main.name
    env = merge(
      { AWS_DEFAULT_REGION = var.aws_region },
      var.aws_profile == "" ? {} : { AWS_PROFILE = var.aws_profile },
    )
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    environment = self.input.env

    command = <<-EOT
      set -euo pipefail
      cluster='${self.input.cluster}'
      tagged() {
        local arns
        arns=$(aws elbv2 "describe-$1" --query "$2[].$3" --output text | tr -d '\r')
        [ -z "$arns" ] && return 0
        aws elbv2 describe-tags --resource-arns $arns \
          --query "TagDescriptions[?Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$cluster']].ResourceArn" \
          --output text | tr -d '\r'
      }
      for attempt in $(seq 60); do
        left="$(tagged load-balancers LoadBalancers LoadBalancerArn) $(tagged target-groups TargetGroups TargetGroupArn) $(aws ec2 describe-security-groups --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$cluster" --query 'SecurityGroups[].GroupId' --output text | tr -d '\r')"
        if [ -z "$(echo "$left" | tr -d '[:space:]')" ]; then
          exit 0
        fi
        sleep 10
      done
      echo "The load balancer controller left these behind after 10 minutes: $left"
      exit 1
    EOT
  }

  depends_on = [
    helm_release.aws_load_balancer_controller,
    helm_release.argocd,
  ]
}
