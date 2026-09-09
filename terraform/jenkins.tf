# Jenkins gets an instance profile rather than static AWS keys, scoped to
# pushing the two ECR repos and nothing else.

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
    resources = ["*"] # AWS does not support resource-level scoping for this action
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
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

# Session Manager access. The bootstrap script sends all of its output to
# /var/log/jenkins-bootstrap.log on the instance, which is unreadable from
# outside without either an SSH key or SSM - and SSM is the one that does not
# need port 22 open to the world.
resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jenkins" {
  name_prefix = "${local.project_name}-jenkins-"
  role        = aws_iam_role.jenkins.name
  tags        = local.common_tags
}

locals {
  jenkins_groovy_script = templatefile("${path.module}/templates/jenkins-init.groovy.tftpl", {
    repo_url               = "https://github.com/${var.github_repo}.git"
    github_username        = var.github_username
    github_pat             = var.github_pat
    jenkins_admin_password = random_password.jenkins_admin.result
    jenkins_webhook_secret = random_password.jenkins_webhook.result
  })
}
