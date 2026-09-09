# The app itself is deployed by ArgoCD (see gitops/argocd-application.yaml), not here.

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version
  namespace        = "ingress-nginx"
  create_namespace = true
  timeout          = 600

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  # Tags the ELB - Kubernetes creates it, not Terraform, so no `tags` arg applies.
  set {
    name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-additional-resource-tags"
    value = "Project=${local.common_tags.Project},Environment=${local.common_tags.Environment},ManagedBy=${local.common_tags.ManagedBy},CreatedBy=${local.common_tags.CreatedBy}"
  }

  depends_on = [aws_eks_node_group.main]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.kube_prometheus_stack_chart_version
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  set_sensitive {
    # Overrides the chart's known default password (generated in admin-passwords.tf).
    name  = "grafana.adminPassword"
    value = random_password.grafana_admin.result
  }

  set {
    # ClusterIP - Grafana is an admin panel, not exposed publicly.
    name  = "grafana.service.type"
    value = "ClusterIP"
  }

  # Without these both default to emptyDir - metrics history and any saved
  # dashboards would be wiped on every pod restart.
  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName"
    value = kubernetes_storage_class.gp3_tagged.metadata[0].name
  }

  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]"
    value = "ReadWriteOnce"
  }

  set {
    name  = "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage"
    value = var.prometheus_storage_size
  }

  set {
    name  = "prometheus.prometheusSpec.retention"
    value = var.prometheus_retention
  }

  set {
    name  = "grafana.persistence.enabled"
    value = "true"
  }

  set {
    name  = "grafana.persistence.storageClassName"
    value = kubernetes_storage_class.gp3_tagged.metadata[0].name
  }

  set {
    name  = "grafana.persistence.size"
    value = var.grafana_storage_size
  }

  depends_on = [
    aws_eks_node_group.main,
    kubernetes_storage_class.gp3_tagged
  ]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  timeout          = 600

  set {
    # ClusterIP - same reasoning as Grafana above.
    name  = "server.service.type"
    value = "ClusterIP"
  }

  depends_on = [aws_eks_node_group.main]
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version
  namespace        = "external-secrets"
  create_namespace = true
  timeout          = 600

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_secrets.arn
  }

  depends_on = [aws_eks_node_group.main, aws_iam_openid_connect_provider.eks]
}
