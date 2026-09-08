# IRSA for External Secrets Operator: lets its pod read AWS Secrets Manager
# without static AWS keys. Bound to the ServiceAccount via helm-addons.tf.

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]

  tags = merge(
    local.common_tags,
    { Name = "${local.project_name}-eks-oidc" }
  )
}

locals {
  oidc_provider_url_no_scheme = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
  # Must match the external-secrets helm_release's namespace + ServiceAccount name.
  eso_service_account = "system:serviceaccount:external-secrets:external-secrets"
}

data "aws_iam_policy_document" "eso_assume_role" {
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
      values   = [local.eso_service_account]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name_prefix        = "${local.project_name}-eso-"
  assume_role_policy = data.aws_iam_policy_document.eso_assume_role.json
  tags               = local.common_tags
}

# Least privilege: read-only access to exactly the one secret this project
# uses, not SecretsManagerReadWrite / not a wildcard over all secrets.
data "aws_iam_policy_document" "eso_secrets_access" {
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:app-secrets*"
    ]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "${local.project_name}-eso-secrets-access"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.eso_secrets_access.json
}
