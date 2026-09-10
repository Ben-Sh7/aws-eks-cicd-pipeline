# The app itself is deployed by ArgoCD (see gitops/argocd-application.yaml), not here.

locals {
  # Alertmanager ships with kube-prometheus-stack and is deployed either way.
  # Left at the chart default it routes everything to a null receiver, so alerts
  # only ever reach its own UI. Setting slack_webhook_url turns on the routing
  # below; leaving it empty keeps the one-command, no-Slack-account promise.
  # nonsensitive: whether Slack is configured is not itself a secret, and this
  # boolean needs to be usable in an output and a plain conditional.
  slack_alerting_enabled = nonsensitive(var.slack_webhook_url != "")

  alertmanager_values = {
    alertmanager = {
      config = {
        global = { resolve_timeout = "5m" }

        route = {
          receiver        = "slack"
          group_by        = ["namespace", "alertname"]
          group_wait      = "30s"
          group_interval  = "5m"
          repeat_interval = "4h"
          routes = [
            # Watchdog fires forever by design (a dead-man's switch you alert on
            # its ABSENCE), and InfoInhibitor is internal plumbing. Neither is a
            # real alert - drop both before they reach Slack.
            {
              receiver = "null"
              matchers = ["alertname =~ \"Watchdog|InfoInhibitor\""]
            },
            {
              receiver = "slack"
              matchers = ["severity =~ \"warning|critical\""]
            },
          ]
        }

        receivers = [
          { name = "null" },
          {
            name = "slack"
            slack_configs = [
              {
                api_url       = var.slack_webhook_url
                channel       = var.slack_channel
                send_resolved = true
                title         = "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }} ({{ .Alerts | len }})"
                text          = "{{ range .Alerts }}{{ .Labels.severity }}: {{ .Annotations.summary }} — {{ .Annotations.description }}\n{{ end }}"
              },
            ]
          },
        ]
      }
    }
  }
}

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

  # Alertmanager routing. Empty list when slack_webhook_url is unset, so the
  # chart default (null receiver) stands. The list is derived from a sensitive
  # variable, so plan shows it as "(sensitive value)".
  values = local.slack_alerting_enabled ? [yamlencode(local.alertmanager_values)] : []

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

  # kube-prometheus-stack assumes a self-managed control plane, where the
  # scheduler, controller-manager and etcd run as scrapeable pods. On EKS they
  # run on AWS's side and are not exposed at all, so Prometheus looks for them,
  # finds nothing, and fires KubeSchedulerDown / KubeControllerManagerDown /
  # etcd alerts at severity critical - on every single run, forever, with
  # nothing anyone can do about them.
  #
  # An alert that is always firing is worse than no alert: it teaches you to
  # ignore the channel. Disabling these drops their ServiceMonitors and their
  # rules. It costs no real visibility, because there was none to lose - EKS
  # control-plane metrics come from CloudWatch or enabled_cluster_log_types,
  # not from scraping. kube-proxy is left enabled: it does run here, as a
  # DaemonSet on the nodes.
  set {
    name  = "kubeScheduler.enabled"
    value = "false"
  }

  set {
    name  = "kubeControllerManager.enabled"
    value = "false"
  }

  set {
    name  = "kubeEtcd.enabled"
    value = "false"
  }

  # Serialised behind ingress-nginx on purpose. The helm provider shares one
  # repository cache and config file across parallel helm_release resources, so
  # creating them concurrently makes all but one fail with "no cached repo
  # found" - on a clean machine that breaks create.sh every time. Chaining costs
  # a few minutes and needs no extra tooling or a warm cache.
  depends_on = [
    aws_eks_node_group.main,
    kubernetes_storage_class.gp3_tagged,
    helm_release.ingress_nginx
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
    # ClusterIP - same reasoning as Grafana above. The only thing reachable from
    # outside is the /api/webhook path, via the dedicated ingress in
    # argocd-webhook.tf; the UI and the rest of the API stay port-forward only.
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # Shared secret GitHub signs its webhook payloads with. Without it ArgoCD
  # accepts unauthenticated pokes on /api/webhook from anyone who can reach it.
  set_sensitive {
    name  = "configs.secret.githubSecret"
    value = random_password.argocd_webhook.result
  }

  depends_on = [aws_eks_node_group.main, helm_release.kube_prometheus_stack]
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

  depends_on = [aws_eks_node_group.main, aws_iam_openid_connect_provider.eks, helm_release.argocd]
}
