data "aws_caller_identity" "current" {}

module "vpc" {
  source = "../../modules/vpc"

  project                  = "pharma"
  env                      = "prod"
  vpc_cidr                 = "10.2.0.0/16"
  public_subnet_cidrs      = ["10.2.1.0/24", "10.2.2.0/24"]
  private_eks_subnet_cidrs = ["10.2.3.0/24", "10.2.4.0/24"]
  private_rds_subnet_cidrs = ["10.2.5.0/24", "10.2.6.0/24"]
}

module "eks" {
  source = "../../modules/eks"

  project            = "pharma"
  env                = "prod"
  cluster_version    = "1.33"
  subnet_ids         = module.vpc.private_eks_subnet_ids
  node_instance_type = "t3.medium"
  desired_capacity   = 2
  min_size           = 2
  max_size           = 5
}

module "rds" {
  source = "../../modules/rds"

  project               = "pharma"
  env                   = "prod"
  subnet_ids            = module.vpc.private_rds_subnet_ids
  vpc_id                = module.vpc.vpc_id
  eks_security_group_id = module.eks.cluster_security_group_id
  db_name               = "pharmadb"
  db_username           = "pharmaadmin"
  db_password           = var.db_password
}

module "ecr" {
  source = "../../modules/ecr"

  project = "pharma"
  env     = "prod"
  repositories = [
    "api-gateway",
    "auth-service",
    "drug-catalog-service",
    "inventory-service",
    "manufacturing-service",
    "notification-service",
    "pharma-ui",
    "supplier-service",
  ]
}

module "iam" {
  source = "../../modules/iam"

  project           = "pharma"
  env               = "prod"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  aws_account_id    = data.aws_caller_identity.current.account_id
  github_org        = var.github_org
}

module "secrets_manager" {
  source = "../../modules/secrets-manager"

  project     = "pharma"
  env         = "prod"
  db_username = "pharmaadmin"
  db_password = var.db_password
  jwt_secret  = var.jwt_secret
}
