# Cluster add-ons: ingress controller, monitoring, GitOps CD, secrets sync.
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
    # Overrides the chart's known default password. No default in
    # variables.tf, so this fails closed if unset.
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }

  set {
    # ClusterIP - Grafana is an admin panel, not exposed publicly.
    name  = "grafana.service.type"
    value = "ClusterIP"
  }

  depends_on = [aws_eks_node_group.main]
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
    # Binds the ServiceAccount to the IRSA role in irsa.tf.
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.external_secrets.arn
  }

  depends_on = [aws_eks_node_group.main, aws_iam_openid_connect_provider.eks]
}
