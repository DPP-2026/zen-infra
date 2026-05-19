terraform {
  backend "s3" {
    bucket       = "zen-pharma-terraform-state-ganeshhhhhh" # Replace with your S3 bucket name
    key          = "envs/qa/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
  }
}
