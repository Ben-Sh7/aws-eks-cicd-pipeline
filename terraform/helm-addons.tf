# Cluster add-ons. The app itself is deployed by ArgoCD, from the Application
# defined at the bottom of this file - Terraform creates the Application, ArgoCD
# does everything after that.
#
# The four releases are chained rather than parallel on purpose: the helm
# provider shares one repository cache and config file across resources, so
# creating them concurrently makes all but one fail with "no cached repo found"
# on a machine with a cold cache. The order also carries real dependencies -
# external-secrets installs the CRDs the monitoring release then uses, and the
# ingress controller's load balancer has to exist before anything is published.

locals {
  # Kubernetes Secrets the monitoring namespace consumes, each filled by
  # External Secrets from an entry in Secrets Manager. The names are referenced
  # both by the ExternalSecret that creates them and by the chart value that
  # mounts them, so they live here once.
  monitoring_secretstore    = "monitoring-secretstore"
  grafana_admin_secret      = "grafana-admin"
  alertmanager_slack_secret = "alertmanager-slack"
  alertmanager_slack_key    = "url"

  # One SecretStore for the namespace. No auth block: the External Secrets pod
  # authenticates to AWS with its IRSA role (irsa.tf), which is allowed to read
  # exactly the entries it syncs - and the GitHub token is not one of them.
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

  # Grafana's admin login. It arrives this way rather than as a Helm value
  # because a Helm value is an argument of the release resource, and would
  # therefore be recorded in Terraform state - which is precisely what
  # generating it with a write-only argument avoids (admin-passwords.tf).
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

  # The Slack URL, out of the entry you maintain by hand. Terraform neither
  # creates nor reads it; it only passes on the name.
  alertmanager_slack_manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.alertmanager_slack_secret
      namespace = "monitoring"
    }
    spec = {
      # An hour, not seconds: this value changes when a human changes it, and
      # every refresh is a billed GetSecretValue call.
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
      # Mounted as one file per key under
      # /etc/alertmanager/secrets/<secret name>/.
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
              # Read from the mounted file, never from this config. Terraform
              # does not know the URL: External Secrets copies it out of
              # Secrets Manager into the cluster, and Alertmanager picks it up
              # from disk. Nothing about it reaches the state file or a
              # rendered Helm value.
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

  # Built as one object rather than two values entries: Helm replaces lists
  # wholesale when merging, so a second entry carrying extraManifests would
  # silently drop the first one's.
  monitoring_values = merge(
    {
      grafana = {
        # Key names inside the Secret are the chart's defaults, so only the
        # Secret itself has to be named.
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

    # Without this the chart default stands - a null receiver, so alerts only
    # ever reach Alertmanager's own UI.
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

  # TLS terminates on the load balancer, with the ACM certificate from dns.tf.
  # The alternative - cert-manager and an ACME issuer inside the cluster - means
  # running another controller, and another thing that can quietly stop renewing
  # a certificate. ACM renews on its own for as long as the validation records
  # exist, and AWS never hands out the private key at all.
  values = [yamlencode({
    controller = {
      service = {
        type = "LoadBalancer"
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"         = aws_acm_certificate_validation.main.certificate_arn
          "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"        = "https"
          "service.beta.kubernetes.io/aws-load-balancer-backend-protocol" = "http"
          # Tags the ELB - Kubernetes creates it, not Terraform, so no `tags`
          # argument reaches it.
          "service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags" = "Project=${local.common_tags.Project},Environment=${local.common_tags.Environment},ManagedBy=${local.common_tags.ManagedBy},CreatedBy=${local.common_tags.CreatedBy}"
        }
        # 443 on the load balancer is decrypted there and forwarded to the
        # controller's plain HTTP port. Without this the controller would expect
        # a second TLS handshake on its https port and every request would fail.
        targetPorts = {
          https = "http"
        }
      }

      config = {
        # nginx now sees plain HTTP for requests that arrived over TLS, so the
        # only way it can tell the difference - and the only way a
        # redirect-to-HTTPS rule can avoid looping forever - is the
        # X-Forwarded-Proto header the load balancer sets.
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

  # Second of the four releases now, not last: it installs the ExternalSecret
  # CRD, and the monitoring release below ships an ExternalSecret of its own. A
  # CRD has to exist before anything of that kind is applied.
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

  # Grafana's admin Secret, the SecretStore behind it, and - when Slack is
  # enabled - the Alertmanager routing and the ExternalSecret that feeds it.
  values = [yamlencode(local.monitoring_values)]

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

  depends_on = [
    aws_eks_node_group.main,
    kubernetes_storage_class.gp3_tagged,
    helm_release.external_secrets,
    # Grafana's pod mounts the Secret the ExternalSecret in here builds, so the
    # value has to be in Secrets Manager before the release is installed.
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

  # The Application that deploys the app.
  #
  # It travels with this release rather than being applied separately because
  # Helm installs a chart's CRDs before its templates, so the Application kind
  # exists by the time this object is created - the ordering problem that makes
  # a standalone kubernetes_manifest resource fail on a from-scratch apply,
  # where the CRD does not exist yet at plan time.
  #
  # Every parameter below is a value that cannot live in git: the ECR URLs
  # contain the AWS account id, the database endpoint and secret names are
  # generated per deployment, and the app's own address comes from the domain.
  # They used to be injected by a shell script that rewrote a YAML file with awk
  # after reading terraform output; here they are ordinary references, checked
  # at plan time.
  values = [yamlencode({
    extraObjects = [
      {
        apiVersion = "argoproj.io/v1alpha1"
        kind       = "Application"
        metadata = {
          name      = "task-manager"
          namespace = "argocd"
          # Makes deletion cascade: everything the app owns (Deployments,
          # Services, Ingress) goes before the Application itself does, which is
          # what keeps a teardown from leaving an orphaned load balancer behind.
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
