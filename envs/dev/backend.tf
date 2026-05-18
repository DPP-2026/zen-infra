# backend configuration

terraform {
  backend "s3" {
<<<<<<< HEAD
    bucket       = "zen-pharma-terraform-state-rameshaws360-us-east-1"  # Replace with your S3 bucket name
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
=======
    bucket = "zen-pharma-terraform-state-chandika-s"
    key    = "envs/dev/terraform.tfstate"
>>>>>>> 01f7ee6a1a7a8d579da1feb93fafc5d3981e244b
    encrypt      = true
    use_lockfile = true   # S3 native locking
  }
}
