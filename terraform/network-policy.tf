resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

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
