data "aws_ecr_repositories" "existing" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  # Only create repos that don't already exist — a repo created outside this
  # module (or left behind by a prior partial apply) is adopted as-is rather
  # than recreated, so its images and settings aren't touched.
  new_repositories = setsubtract(toset(var.repositories), toset(data.aws_ecr_repositories.existing.names))

  # Covers every repo in var.repositories, not just the ones this module
  # created, so consumers of repository_urls see pre-existing repos too.
  repository_urls = {
    for name in var.repositories :
    name => "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.name}.amazonaws.com/${name}"
  }
}

resource "aws_ecr_repository" "main" {
  for_each = local.new_repositories

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name    = "${var.project}-${each.value}"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_ecr_lifecycle_policy" "main" {
  for_each   = local.new_repositories
  repository = aws_ecr_repository.main[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
