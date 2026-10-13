resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  preserve                    = true

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
    env = {
      NETWORK_POLICY_ENFORCING_MODE = "standard"
      ENABLE_PREFIX_DELEGATION      = "true"
      WARM_PREFIX_TARGET            = "1"
    }
  })

  tags = local.common_tags

  depends_on = [aws_eks_node_group.main]
}

locals {
  namespaces_kept_off_the_database = toset([
    "default",
    "kube-system",
    helm_release.ingress_nginx.namespace,
    helm_release.external_secrets.namespace,
    kubernetes_namespace.monitoring.metadata[0].name,
    helm_release.argocd.namespace,
    kubernetes_namespace.jenkins.metadata[0].name,
    helm_release.trivy_operator.namespace,
  ])
}

resource "kubernetes_network_policy_v1" "keep_off_the_database" {
  for_each = local.namespaces_kept_off_the_database

  metadata {
    name      = "keep-off-the-database"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {}
      }
    }

    egress {
      to {
        ip_block {
          cidr   = "0.0.0.0/0"
          except = local.db_subnet_cidrs
        }
      }
    }
  }

  depends_on = [aws_eks_addon.vpc_cni]
}

resource "kubernetes_network_policy_v1" "postgres_exporter_to_database" {
  metadata {
    name      = "postgres-exporter-to-database"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        "app.kubernetes.io/name" = "prometheus-postgres-exporter"
      }
    }
    policy_types = ["Egress"]

    egress {
      dynamic "to" {
        for_each = local.db_subnet_cidrs
        content {
          ip_block {
            cidr = to.value
          }
        }
      }

      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }
  }

  depends_on = [aws_eks_addon.vpc_cni]
}
