locals {
  jenkins_namespace       = "jenkins"
  jenkins_service_account = "jenkins-agent"
  jenkins_secretstore     = "jenkins-secretstore"
  jenkins_k8s_secret      = "jenkins-secrets"
  jenkins_workload        = "jenkins"

  jenkins_tolerations = [
    {
      key      = "workload"
      operator = "Equal"
      value    = local.jenkins_workload
      effect   = "NoSchedule"
    },
  ]

  jenkins_extra_objects = [
    {
      apiVersion = "external-secrets.io/v1beta1"
      kind       = "SecretStore"
      metadata = {
        name      = local.jenkins_secretstore
        namespace = local.jenkins_namespace
      }
      spec = {
        provider = {
          aws = {
            service = "SecretsManager"
            region  = var.aws_region
          }
        }
      }
    },
    {
      apiVersion = "external-secrets.io/v1beta1"
      kind       = "ExternalSecret"
      metadata = {
        name      = local.jenkins_k8s_secret
        namespace = local.jenkins_namespace
      }
      spec = {
        refreshInterval = "1h"
        secretStoreRef = {
          name = local.jenkins_secretstore
          kind = "SecretStore"
        }
        target = {
          name           = local.jenkins_k8s_secret
          creationPolicy = "Owner"
        }
        data = [
          {
            secretKey = "jenkins-admin-user"
            remoteRef = {
              key      = aws_secretsmanager_secret.jenkins_admin.name
              property = "username"
            }
          },
          {
            secretKey = "jenkins-admin-password"
            remoteRef = {
              key      = aws_secretsmanager_secret.jenkins_admin.name
              property = "password"
            }
          },
          {
            secretKey = "github-pat"
            remoteRef = { key = data.aws_secretsmanager_secret.github_token.name }
          },
          {
            secretKey = "webhook-secret"
            remoteRef = { key = aws_secretsmanager_secret.jenkins_webhook.name }
          },
        ]
      }
    },
  ]

  jenkins_jcasc = {
    credentials = {
      system = {
        domainCredentials = [
          {
            credentials = [
              {
                usernamePassword = {
                  scope       = "GLOBAL"
                  id          = "github-credentials"
                  username    = local.github_username
                  password    = "$${${local.jenkins_k8s_secret}-github-pat}"
                  description = "GitHub token, for cloning and for the deploy commit"
                }
              },
              {
                string = {
                  scope       = "GLOBAL"
                  id          = "github-webhook-secret"
                  secret      = "$${${local.jenkins_k8s_secret}-webhook-secret}"
                  description = "Shared secret GitHub signs webhook payloads with"
                }
              },
            ]
          },
        ]
      }
    }

    unclassified = {
      gitHubPluginConfig = {
        hookSecretConfigs = [
          { credentialsId = "github-webhook-secret" },
        ]
      }
    }

    jobs = [
      {
        script = <<-EOT
          pipelineJob('task-manager') {
            description('Builds the app, scans it, and hands the tag to ArgoCD')
            definition {
              cpsScm {
                lightweight(true)
                scm {
                  git {
                    remote {
                      url('https://github.com/${local.github_repo}.git')
                      credentials('github-credentials')
                    }
                    branch('*/${var.ci_revision}')
                  }
                }
                scriptPath('Jenkinsfile')
              }
            }
            triggers {
              githubPush()
              scm('H/5 * * * *')
            }
          }
        EOT
      },
    ]
  }

  jenkins_values = {
    extraObjects = local.jenkins_extra_objects

    controller = {
      additionalPlugins = [
        "github:${var.jenkins_github_plugin_version}",
        "job-dsl:${var.jenkins_job_dsl_plugin_version}",
        "prometheus:${var.jenkins_prometheus_plugin_version}",
      ]

      admin = {
        existingSecret = local.jenkins_k8s_secret
      }

      additionalExistingSecrets = [
        {
          name    = local.jenkins_k8s_secret
          keyName = "github-pat"
        },
        {
          name    = local.jenkins_k8s_secret
          keyName = "webhook-secret"
        },
      ]

      JCasC = {
        defaultConfig = true
        configScripts = {
          "task-manager" = yamlencode(local.jenkins_jcasc)
        }
      }

      jenkinsUrl = "https://${local.jenkins_fqdn}"

      ingress = {
        enabled          = true
        ingressClassName = "nginx"
        hostName         = local.jenkins_fqdn

        annotations = {
          "nginx.ingress.kubernetes.io/whitelist-source-range" = join(",", concat(local.github_hook_cidrs, local.jenkins_ui_cidrs))
        }
      }

      nodeSelector = { workload = local.jenkins_workload }
      tolerations  = local.jenkins_tolerations

      resources = {
        requests = {
          cpu    = "300m"
          memory = "1Gi"
        }
        limits = {
          memory = "2Gi"
        }
      }

      prometheus = {
        enabled = true
      }
    }

    agent = {
      nodeSelector = { workload = local.jenkins_workload }
      yamlTemplate = yamlencode({
        apiVersion = "v1"
        kind       = "Pod"
        spec = {
          tolerations = local.jenkins_tolerations
        }
      })
    }

    persistence = {
      storageClass = kubernetes_storage_class.gp3_tagged.metadata[0].name
      size         = var.jenkins_storage_size
    }

    serviceAccountAgent = {
      create      = true
      name        = local.jenkins_service_account
      annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.jenkins_agent.arn }
    }
  }
}

resource "aws_eks_node_group" "jenkins" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.project_name}-jenkins"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [aws_subnet.private_1.id, aws_subnet.private_2.id]
  version         = var.kubernetes_version

  scaling_config {
    desired_size = 1
    max_size     = var.jenkins_node_max_size
    min_size     = 1
  }

  instance_types = [var.jenkins_node_instance_type]

  labels = { workload = local.jenkins_workload }

  taint {
    key    = "workload"
    value  = local.jenkins_workload
    effect = "NO_SCHEDULE"
  }

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.project_name}-jenkins-nodes"

      "k8s.io/cluster-autoscaler/node-template/label/workload" = local.jenkins_workload
      "k8s.io/cluster-autoscaler/node-template/taint/workload" = "${local.jenkins_workload}:NoSchedule"
    }
  )

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_registry_policy,
    aws_route.private_nat,
    aws_route_table_association.private_1,
    aws_route_table_association.private_2,
  ]
}

data "aws_iam_policy_document" "jenkins_agent_assume_role" {
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
      values   = ["system:serviceaccount:${local.jenkins_namespace}:${local.jenkins_service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url_no_scheme}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins_agent" {
  name_prefix        = "${local.project_name}-jenkins-"
  assume_role_policy = data.aws_iam_policy_document.jenkins_agent_assume_role.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "jenkins_agent_ecr_push" {
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

resource "aws_iam_role_policy" "jenkins_agent_ecr_push" {
  name   = "${local.project_name}-jenkins-ecr-push"
  role   = aws_iam_role.jenkins_agent.id
  policy = data.aws_iam_policy_document.jenkins_agent_ecr_push.json
}

resource "kubernetes_namespace" "jenkins" {
  metadata {
    name = local.jenkins_namespace
  }

  depends_on = [terraform_data.volume_cleanup_gate]
}

resource "helm_release" "jenkins" {
  name       = "jenkins"
  repository = "https://charts.jenkins.io"
  chart      = "jenkins"
  version    = var.jenkins_chart_version
  namespace  = kubernetes_namespace.jenkins.metadata[0].name
  timeout    = 900

  values = [yamlencode(local.jenkins_values)]

  depends_on = [
    aws_eks_node_group.jenkins,
    kubernetes_storage_class.gp3_tagged,
    helm_release.ingress_nginx,
    helm_release.external_secrets,
    aws_secretsmanager_secret_version.jenkins_admin,
    aws_secretsmanager_secret_version.jenkins_webhook,
    aws_iam_role_policy.jenkins_agent_ecr_push,
  ]
}
