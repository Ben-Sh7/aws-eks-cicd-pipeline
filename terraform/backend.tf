# Where the state lives.
#
# Not on the machine running the apply. State is not a byproduct - it is the
# only record of what exists in the account, and it contains generated
# passwords in clear text. A local terraform.tfstate means that record is
# unencrypted, unversioned, unlocked, and lost with the laptop.
#
# What this buys, in order of how much it matters:
#   - encryption at rest with a key of your own, and TLS enforced by bucket
#     policy (see bootstrap/)
#   - versioning, so a corrupted state is one restore away instead of a rebuild
#   - locking, so two applies cannot run at once and overwrite each other
#   - one shared source of truth, which is what makes running apply from CI
#     rather than from a laptop possible at all
#
# The bucket is created by bootstrap/ and must exist before `terraform init`.
# A backend block cannot use variables or interpolation - it is read before
# anything else is evaluated - so the bucket name is literal here and has a
# matching default in bootstrap/main.tf. Those two are the only places it
# appears; if you change one, change the other.
terraform {
  backend "s3" {
    bucket = "ben-sh7-task-manager-tfstate"
    key    = "task-manager/terraform.tfstate"
    region = "us-east-1"

    # The bucket's default encryption already applies the KMS key, so no key id
    # is repeated here; this asks S3 for server-side encryption on every write.
    encrypt = true

    # S3's own conditional-write locking (Terraform 1.10+). The DynamoDB table
    # that used to be required for this is no longer needed - one less resource
    # to create, pay for and explain.
    use_lockfile = true
  }
}
