# EBS CSI driver - the in-tree provisioner was removed in Kubernetes 1.23+,
# so the Postgres PVC needs this to provision at all.

data "aws_iam_policy_document" "ebs_csi_assume_role" {
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
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name_prefix        = "${local.project_name}-ebs-csi-"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
  tags                     = local.common_tags

  depends_on = [aws_eks_node_group.main]
}

resource "kubernetes_storage_class" "gp3_tagged" {
  metadata {
    name = "gp3-tagged"
  }

  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type               = "gp3"
    tagSpecification_1 = "Project=${local.common_tags.Project}"
    tagSpecification_2 = "Environment=${local.common_tags.Environment}"
    tagSpecification_3 = "ManagedBy=${local.common_tags.ManagedBy}"
    tagSpecification_4 = "CreatedBy=${local.common_tags.CreatedBy}"
    tagSpecification_5 = "CreatedDate=${local.common_tags.CreatedDate}"
  }

  depends_on = [aws_eks_addon.ebs_csi_driver]
}
