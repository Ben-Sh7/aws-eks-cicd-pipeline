terraform {
  backend "s3" {
    bucket = "ben-sh7-task-manager-tfstate"
    key    = "task-manager/terraform.tfstate"
    region = "us-east-1"

    encrypt = true

    use_lockfile = true
  }
}
