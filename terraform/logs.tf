locals {
  loki_service_account = "loki"
  loki_url             = "http://loki.monitoring.svc.cluster.local:3100"

  loki_values = {
    deploymentMode = "SingleBinary"

    loki = {
      auth_enabled = false

      commonConfig = {
        replication_factor = 1
      }

      schemaConfig = {
        configs = [
          {
            from         = "2024-04-01"
            store        = "tsdb"
            object_store = "s3"
            schema       = "v13"
            index = {
              prefix = "loki_index_"
              period = "24h"
            }
          },
        ]
      }

      storage = {
        type = "s3"
        bucketNames = {
          chunks = aws_s3_bucket.loki.bucket
          ruler  = aws_s3_bucket.loki.bucket
          admin  = aws_s3_bucket.loki.bucket
        }
        s3 = {
          region = var.aws_region
        }
      }

      limits_config = {
        retention_period           = var.loki_retention
        reject_old_samples         = true
        reject_old_samples_max_age = "24h"
      }

      compactor = {
        retention_enabled    = true
        delete_request_store = "s3"
      }

      analytics = {
        reporting_enabled = false
      }
    }

    serviceAccount = {
      create      = true
      name        = local.loki_service_account
      annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.loki.arn }
    }

    singleBinary = {
      replicas = 1

      persistence = {
        enabled      = true
        size         = var.loki_storage_size
        storageClass = kubernetes_storage_class.gp3_tagged.metadata[0].name
      }

      resources = {
        requests = {
          cpu    = "100m"
          memory = "256Mi"
        }
        limits = {
          memory = "1Gi"
        }
      }
    }

    write   = { replicas = 0 }
    read    = { replicas = 0 }
    backend = { replicas = 0 }

    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    lokiCanary   = { enabled = false }
    test         = { enabled = false }
    gateway      = { enabled = false }

    monitoring = {
      dashboards     = { enabled = false }
      rules          = { enabled = false }
      serviceMonitor = { enabled = true }
    }
  }

  alloy_config = <<-EOT
    discovery.kubernetes "pods" {
      role = "pod"

      selectors {
        role  = "pod"
        field = "spec.nodeName=" + sys.env("NODE_NAME")
      }
    }

    discovery.relabel "pod_logs" {
      targets = discovery.kubernetes.pods.targets

      rule {
        source_labels = ["__meta_kubernetes_namespace"]
        target_label  = "namespace"
      }

      rule {
        source_labels = ["__meta_kubernetes_pod_name"]
        target_label  = "pod"
      }

      rule {
        source_labels = ["__meta_kubernetes_pod_container_name"]
        target_label  = "container"
      }

      rule {
        source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
        target_label  = "app"
      }

      rule {
        source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
        separator     = "/"
        target_label  = "__path__"
        replacement   = "/var/log/pods/*$1/*.log"
      }
    }

    local.file_match "pod_logs" {
      path_targets = discovery.relabel.pod_logs.output
    }

    loki.source.file "pod_logs" {
      targets    = local.file_match.pod_logs.targets
      forward_to = [loki.process.pod_logs.receiver]
    }

    loki.process "pod_logs" {
      stage.cri { }

      forward_to = [loki.write.loki.receiver]
    }

    loki.write "loki" {
      endpoint {
        url = "${local.loki_url}/loki/api/v1/push"
      }
    }
  EOT

  alloy_values = {
    alloy = {
      configMap = {
        content = local.alloy_config
      }

      mounts = {
        varlog = true

        extra = [
          {
            name      = "alloy-data"
            mountPath = "/tmp/alloy"
          },
        ]
      }

      extraEnv = [
        {
          name = "NODE_NAME"
          valueFrom = {
            fieldRef = {
              fieldPath = "spec.nodeName"
            }
          }
        },
      ]

      securityContext = {
        runAsUser                = 0
        runAsGroup               = 0
        readOnlyRootFilesystem   = true
        allowPrivilegeEscalation = false
        capabilities             = { drop = ["ALL"] }
      }

      enableReporting = false

      resources = {
        requests = {
          cpu    = "50m"
          memory = "128Mi"
        }
        limits = {
          memory = "256Mi"
        }
      }
    }

    controller = {
      type = "daemonset"

      volumes = {
        extra = [
          {
            name     = "alloy-data"
            emptyDir = {}
          },
        ]
      }
    }

    serviceMonitor = {
      enabled = true
    }
  }
}

resource "aws_s3_bucket" "loki" {
  bucket_prefix = "${local.project_name}-loki-"
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "loki" {
  bucket                  = aws_s3_bucket.loki.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "loki" {
  bucket = aws_s3_bucket.loki.id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.loki_bucket_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "loki_assume_role" {
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
      values   = ["system:serviceaccount:monitoring:${local.loki_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "loki" {
  name_prefix        = "${local.project_name}-loki-"
  assume_role_policy = data.aws_iam_policy_document.loki_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "loki_bucket_access" {
  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.loki.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.loki.arn}/*"]
  }
}

resource "aws_iam_role_policy" "loki_bucket_access" {
  name   = "${local.project_name}-loki-bucket-access"
  role   = aws_iam_role.loki.id
  policy = data.aws_iam_policy_document.loki_bucket_access.json
}

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_chart_version
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  timeout    = 600

  values = [yamlencode(local.loki_values)]

  depends_on = [
    aws_eks_node_group.main,
    kubernetes_storage_class.gp3_tagged,
    aws_iam_role_policy.loki_bucket_access,
    helm_release.kube_prometheus_stack,
  ]
}

resource "helm_release" "alloy" {
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.alloy_chart_version
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  timeout    = 600

  values = [yamlencode(local.alloy_values)]

  depends_on = [helm_release.loki]
}
