terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null
}

variable "aws_region" {
  description = "Region the state bucket lives in. Must match the region in ../backend.tf."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Named AWS profile, if not using the default credential chain."
  type        = string
  default     = ""
}

variable "state_bucket_name" {
  description = "Name of the state bucket. S3 bucket names are GLOBALLY unique, so if this one is taken, change it here AND in ../backend.tf - those two must always match."
  type        = string
  default     = "ben-sh7-task-manager-tfstate"
}

locals {
  common_tags = {
    Project   = "task-manager"
    Purpose   = "terraform-remote-state"
    ManagedBy = "IaC"
  }
}

resource "aws_kms_key" "state" {
  description             = "Encrypts the Terraform state of the task-manager project"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_kms_alias" "state" {
  name          = "alias/task-manager-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket_name

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "state_tls_only" {
  statement {
    sid     = "DenyUnencryptedTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_tls_only.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

output "next_step" {
  value = <<-EOT
    State bucket ready: ${aws_s3_bucket.state.id}  (KMS: ${aws_kms_alias.state.name})

    It already matches ../backend.tf, so:

      cd .. && terraform init

    If you changed state_bucket_name, change bucket in ../backend.tf to match.
  EOT
}
