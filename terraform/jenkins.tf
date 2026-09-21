data "aws_iam_policy_document" "jenkins_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name_prefix        = "${local.project_name}-jenkins-"
  assume_role_policy = data.aws_iam_policy_document.jenkins_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "jenkins_ecr_push" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = [
      aws_ecr_repository.backend.arn,
      aws_ecr_repository.frontend.arn,
    ]
  }
}

resource "aws_iam_role_policy" "jenkins_ecr_push" {
  name   = "${local.project_name}-jenkins-ecr-push"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_ecr_push.json
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jenkins" {
  name_prefix = "${local.project_name}-jenkins-"
  role        = aws_iam_role.jenkins.name
  tags        = local.common_tags
}

data "aws_iam_policy_document" "jenkins_bootstrap_secrets" {
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      data.aws_secretsmanager_secret.github_token.arn,
      aws_secretsmanager_secret.jenkins_admin.arn,
      aws_secretsmanager_secret.jenkins_webhook.arn,
    ]
  }
}

resource "aws_iam_role_policy" "jenkins_bootstrap_secrets" {
  name   = "${local.project_name}-jenkins-bootstrap-secrets"
  role   = aws_iam_role.jenkins.id
  policy = data.aws_iam_policy_document.jenkins_bootstrap_secrets.json
}

locals {
  jenkins_secrets_dir = "/var/lib/jenkins/bootstrap-secrets"

  jenkins_groovy_script = templatefile("${path.module}/templates/jenkins-init.groovy.tftpl", {
    repo_url        = "https://github.com/${local.github_repo}.git"
    github_username = local.github_username
    secrets_dir     = local.jenkins_secrets_dir
  })
}
