# backend configuration

terraform {
  backend "s3" {
    bucket       = "zen-pharma-terraform-state-felixlobo"
    key          = "envs/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
