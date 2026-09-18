# The bucket the main configuration keeps its state in.
#
# This is the chicken-and-egg corner of every Terraform setup: the remote
# backend cannot be created by the configuration that uses it. The usual answers
# are to create the bucket with two CLI commands, or to keep a tiny separate
# configuration like this one. This is the second, because the properties that
# make a state bucket safe - versioning, encryption, no public access, no
# plaintext transport - are exactly the kind of thing that should be written
# down as code rather than typed once and forgotten.
#
# Run once per AWS account:
#
#   cd terraform/bootstrap && terraform init && terraform apply
#
# Then, in ../: terraform init  (it will pick up backend.tf)
#
# This configuration keeps its own state in a local file next to it, and that is
# fine: it holds a bucket and a KMS key, and no secret of any kind. It is also
# not something you run again - `terraform destroy` here would delete the state
# of everything else, so it deliberately has nothing pointing at it.

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

# A customer-managed key rather than the default S3 key, for one reason that
# matters: with a key of your own you control who may decrypt, in the key policy,
# independently of who can reach the bucket. Automatic rotation is on - it
# re-keys yearly and keeps the old material, so old state versions stay readable.
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

  # No force_destroy on purpose: this bucket holds the only record of what
  # exists in the account. Emptying it by accident is not a recoverable mistake.
  tags = local.common_tags
}

# The single most useful property of a state bucket. A corrupted or truncated
# state - a killed apply, a bad import, someone's mistake - is recoverable by
# restoring the previous version, and unrecoverable without this.
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

    # Uses one data key per bucket instead of one per object, which is what
    # keeps KMS request charges on a file written hundreds of times negligible.
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

# Encryption at rest is set above; this is the transport half. Without it, a
# client that asks for plain HTTP gets plain HTTP, and the state file - which
# contains generated passwords - crosses the network in the clear.
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

  # The public access block has to be in place first, or S3 can reject a policy
  # on a bucket it considers publicly writable.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

# Versioning without this grows forever. Ninety days of history is far more than
# is ever needed to undo a bad apply, and old state versions are not something
# anyone should be able to read years later.
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
