# backend configuration

terraform {
  backend "s3" {
    bucket = "zen-pharma-terraform-state-awsrbu"
    key    = "envs/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true   # S3 native locking
  }
}
