locals {
  monitoring_secretstore    = "monitoring-secretstore"
  grafana_admin_secret      = "grafana-admin"
  alertmanager_slack_secret = "alertmanager-slack"
  alertmanager_slack_key    = "url"

  monitoring_secretstore_manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "SecretStore"
    metadata = {
      name      = local.monitoring_secretstore
      namespace = "monitoring"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
        }
      }
    }
  }

  grafana_admin_manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.grafana_admin_secret
      namespace = "monitoring"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = local.monitoring_secretstore
        kind = "SecretStore"
      }
      target = {
        name           = local.grafana_admin_secret
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = "admin-user"
          remoteRef = {
            key      = aws_secretsmanager_secret.grafana_admin.name
            property = "admin-user"
          }
        },
        {
          secretKey = "admin-password"
          remoteRef = {
            key      = aws_secretsmanager_secret.grafana_admin.name
            property = "admin-password"
          }
        },
      ]
    }
  }

  alertmanager_slack_manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.alertmanager_slack_secret
      namespace = "monitoring"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = local.monitoring_secretstore
        kind = "SecretStore"
      }
      target = {
        name           = local.alertmanager_slack_secret
        creationPolicy = "Owner"
      }
      data = [
        {
          secretKey = local.alertmanager_slack_key
          remoteRef = {
            key      = data.aws_secretsmanager_secret.app.name
            property = "SLACK_WEBHOOK_URL"
          }
        },
      ]
    }
  }

  alertmanager_config = {
    alertmanagerSpec = {
      secrets = [local.alertmanager_slack_secret]
    }

    config = {
      global = { resolve_timeout = "5m" }

      route = {
        receiver        = "slack"
        group_by        = ["namespace", "alertname"]
        group_wait      = "30s"
        group_interval  = "5m"
        repeat_interval = "4h"
        routes = [
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
              api_url_file  = "/etc/alertmanager/secrets/${local.alertmanager_slack_secret}/${local.alertmanager_slack_key}"
              channel       = var.slack_channel
              send_resolved = true
              title         = "[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }} ({{ .Alerts | len }})"
              text          = "{{ range .Alerts }}{{ .Labels.severity }}: {{ .Annotations.summary }} - {{ .Annotations.description }}\n{{ end }}"
            },
          ]
        },
      ]
    }
  }

  monitoring_values = merge(
    {
      grafana = {
        admin = {
          existingSecret = local.grafana_admin_secret
        }
      }

      extraManifests = concat(
        [
          local.monitoring_secretstore_manifest,
          local.grafana_admin_manifest,
        ],
        var.enable_slack_alerts ? [local.alertmanager_slack_manifest] : [],
      )
    },

    var.enable_slack_alerts ? { alertmanager = local.alertmanager_config } : {},
  )
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_nginx_chart_version
  namespace        = "ingress-nginx"
  create_namespace = true
  timeout          = 600

  values = [yamlencode({
    controller = {
      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"                 = aws_acm_certificate_validation.main.certificate_arn
          "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"                = "https"
          "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"         = "http"
          "service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags" = "Project=${local.common_tags.Project},Environment=${local.common_tags.Environment},ManagedBy=${local.common_tags.ManagedBy},CreatedBy=${local.common_tags.CreatedBy}"
        }
        targetPorts = {
          https = "http"
        }
      }

      config = {
        use-forwarded-headers = "true"
      }
    }
  })]

  depends_on = [
    aws_eks_node_group.main,
    aws_acm_certificate_validation.main,
  ]
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

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_openid_connect_provider.eks,
    helm_release.ingress_nginx,
  ]
}

resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.kube_prometheus_stack_chart_version
  namespace        = "monitoring"
  create_namespace = true
  timeout          = 600

  values = [yamlencode(local.monitoring_values)]

  set {
    name  = "grafana.service.type"
    value = "ClusterIP"
  }

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

  depends_on = [
    aws_eks_node_group.main,
    kubernetes_storage_class.gp3_tagged,
    helm_release.external_secrets,
    aws_secretsmanager_secret_version.grafana_admin,
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
    name  = "server.service.type"
    value = "ClusterIP"
  }

  set_sensitive {
    name  = "configs.secret.githubSecret"
    value = random_password.argocd_webhook.result
  }

  values = [yamlencode({
    extraObjects = [
      {
        apiVersion = "argoproj.io/v1alpha1"
        kind       = "Application"
        metadata = {
          name       = "task-manager"
          namespace  = "argocd"
          finalizers = ["resources-finalizer.argocd.argoproj.io"]
        }
        spec = {
          project = "default"

          source = {
            repoURL        = "https://github.com/${local.github_repo}.git"
            targetRevision = "main"
            path           = "gitops/task-manager"
            helm = {
              valueFiles = ["values.yaml", "values-images.yaml"]
              parameters = [
                { name = "config.dbHost", value = aws_db_instance.postgres.address },
                { name = "config.appUrl", value = local.app_url },
                { name = "secrets.awsRegion", value = var.aws_region },
                { name = "secrets.awsSecretName", value = aws_db_instance.postgres.master_user_secret[0].secret_arn },
                { name = "secrets.jwtSecretName", value = aws_secretsmanager_secret.jwt_secret.name },
                { name = "secrets.googleSecretName", value = data.aws_secretsmanager_secret.app.name },
                { name = "backend.image.repository", value = aws_ecr_repository.backend.repository_url },
                { name = "frontend.image.repository", value = aws_ecr_repository.frontend.repository_url },
                { name = "ingress.host", value = local.app_fqdn },
              ]
            }
          }

          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "default"
          }

          syncPolicy = {
            automated = {
              selfHeal = true
              prune    = true
            }
          }
        }
      },
    ]
  })]

  depends_on = [
    aws_eks_node_group.main,
    helm_release.kube_prometheus_stack,
  ]
}
