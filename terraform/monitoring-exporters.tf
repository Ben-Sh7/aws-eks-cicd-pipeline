ephemeral "aws_secretsmanager_random_password" "db_monitor" {
  password_length     = 40
  exclude_punctuation = true
}

resource "aws_secretsmanager_secret" "db_monitor" {
  name_prefix             = "${local.project_name}/db-monitor-"
  description             = "Read-only Postgres login the metrics exporter uses. Holds pg_monitor and nothing else - it can read statistics and no table data."
  recovery_window_in_days = 0
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "db_monitor" {
  secret_id = aws_secretsmanager_secret.db_monitor.id

  secret_string_wo = jsonencode({
    username = var.db_monitor_username
    password = ephemeral.aws_secretsmanager_random_password.db_monitor.random_password
  })

  secret_string_wo_version = var.generated_secret_version
}

resource "helm_release" "blackbox_exporter" {
  name       = "blackbox-exporter"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-blackbox-exporter"
  version    = var.blackbox_exporter_chart_version
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  timeout    = 600

  values = [yamlencode({
    resources = {
      requests = { cpu = "10m", memory = "32Mi" }
      limits   = { memory = "64Mi" }
    }

    serviceMonitor = {
      enabled = true
      defaults = {
        module        = "http_2xx"
        interval      = "60s"
        scrapeTimeout = "15s"
      }
      targets = [
        {
          name = "app"
          url  = "${local.app_url}/login"
        },
        {
          name = "app-redirect"
          url  = "http://${local.app_fqdn}/"
        },
      ]
    }
  })]

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "helm_release" "postgres_exporter" {
  name       = "postgres-exporter"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-postgres-exporter"
  version    = var.postgres_exporter_chart_version
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  timeout    = 600

  values = [yamlencode({
    resources = {
      requests = { cpu = "10m", memory = "32Mi" }
      limits   = { memory = "64Mi" }
    }

    config = {
      datasource = {
        host     = aws_db_instance.postgres.address
        port     = tostring(aws_db_instance.postgres.port)
        database = var.rds_db_name
        sslmode  = "require"

        userSecret = {
          name = local.db_monitor_k8s_secret
          key  = "username"
        }

        passwordSecret = {
          name = local.db_monitor_k8s_secret
          key  = "password"
        }
      }
    }

    serviceMonitor = {
      enabled = true
    }
  })]

  depends_on = [
    helm_release.kube_prometheus_stack,
    aws_secretsmanager_secret_version.db_monitor,
  ]
}
