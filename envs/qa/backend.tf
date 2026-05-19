terraform {
  backend "s3" {
    bucket = "zen-pharma-terraform-state-chavansb"
    key    = "envs/qa/terraform.tfstate"
    encrypt      = true
    use_lockfile = true   # S3 native locking — requires Terraform 1.10+, no DynamoDB needed
  }
}
