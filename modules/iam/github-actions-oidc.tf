# ─── GitHub Actions OIDC Federation ─────────────────────────────────────────
#
# Allows GitHub Actions workflows in your-github-username/zen-pharma-frontend and
# your-github-username/zen-pharma-backend to assume an IAM role without any long-lived
# AWS credentials stored in GitHub Secrets.
#
# How it works:
#   1. GitHub mints a short-lived OIDC token per workflow run.
#   2. The workflow calls aws-actions/configure-aws-credentials with
#      role-to-assume: <this role ARN>.
#   3. AWS validates the token against the registered OIDC provider and
#      issues temporary STS credentials (valid for 1 hour max).
#
# Usage in workflow:
#   - uses: aws-actions/configure-aws-credentials@v4
#     with:
#       role-to-assume: arn:aws:iam::ACCOUNT_ID:role/pharma-dev-github-actions-role
#       aws-region: us-east-1
# ─────────────────────────────────────────────────────────────────────────────

# GitHub Actions OIDC provider — one per AWS account, shared across all repos
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # Thumbprint for token.actions.githubusercontent.com (stable, verified by AWS)
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = {
    Name    = "github-actions-oidc-provider"
    Project = var.project
  }
}

# Trust policy — restricts which repos and branches can assume this role
data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Allow both frontend and backend repos; restrict to main and develop branches
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/zen-pharma-frontend:ref:refs/heads/main",
        "repo:${var.github_org}/zen-pharma-frontend:ref:refs/heads/develop",
        "repo:${var.github_org}/zen-pharma-backend:ref:refs/heads/main",
        "repo:${var.github_org}/zen-pharma-backend:ref:refs/heads/develop",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_ci" {
  name                 = "${var.project}-${var.env}-github-actions-role"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume_role.json
  max_session_duration = 3600 # 1 hour — enough for any CI job

  tags = {
    Name    = "${var.project}-${var.env}-github-actions-role"
    Env     = var.env
    Project = var.project
  }
}

# Permissions: push images to ECR + read cluster info (no kubectl apply — ArgoCD does that)
resource "aws_iam_policy" "github_actions_ci_policy" {
  name        = "${var.project}-${var.env}-github-actions-policy"
  description = "Allow GitHub Actions CI to push images to ECR and read EKS cluster info"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages",
        ]
        # Allow all ECR repos in this account (role is already scoped to specific GitHub repos via trust policy)
        Resource = "arn:aws:ecr:*:${var.aws_account_id}:repository/*"
      },
      {
        Sid    = "EKSRead"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_ci_policy_attachment" {
  role       = aws_iam_role.github_actions_ci.name
  policy_arn = aws_iam_policy.github_actions_ci_policy.arn
}
