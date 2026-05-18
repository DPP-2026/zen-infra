terraform {
  backend "s3" {
<<<<<<< HEAD
    bucket       = "zen-pharma-terraform-state-rameshaws360"  # Replace with your S3 bucket name
    key          = "envs/qa/terraform.tfstate"
    region       = "us-east-1"
=======
    bucket = "zen-pharma-terraform-state-dpp-2026"
    key    = "envs/qa/terraform.tfstate"
>>>>>>> 01f7ee6a1a7a8d579da1feb93fafc5d3981e244b
    encrypt      = true
    use_lockfile = true   # S3 native locking — requires Terraform 1.10+, no DynamoDB needed
  }
}
