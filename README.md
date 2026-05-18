# zen-infra — Implementation Guide

![Infra Setup](docs/architecture.jpg)
# Test

This guide walks you through setting up the zen-pharma infrastructure on your own AWS account from scratch using this repository. Follow each section in order.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites](#2-prerequisites)
3. [Repository Structure](#3-repository-structure)
4. [Step 1 — AWS Account Setup](#4-step-1--aws-account-setup)
5. [Step 2 — S3 State Backend Setup](#5-step-2--s3-state-backend-setup)
6. [Step 3 — Fork and Configure the Repository](#6-step-3--fork-and-configure-the-repository)
7. [Step 4 — Update Configuration for Your Account](#7-step-4--update-configuration-for-your-account)
8. [Step 5 — GitHub Secrets Setup](#8-step-5--github-secrets-setup)
9. [Step 6 — GitHub Environment Setup](#9-step-6--github-environment-setup)
10. [Step 7 — Provision Infrastructure via Pipeline](#10-step-7--provision-infrastructure-via-pipeline)
11. [Step 8 — Verify the Infrastructure](#11-step-8--verify-the-infrastructure)
12. [Infrastructure Details](#12-infrastructure-details)
13. [Day-2 Operations](#13-day-2-operations)
14. [Destroying Infrastructure](#14-destroying-infrastructure)
15. [Troubleshooting](#15-troubleshooting)

---

## 1. Architecture Overview

This repository provisions a complete Kubernetes-based platform on AWS for the zen-pharma
application. All infrastructure is defined as code in Terraform and deployed automatically
via GitHub Actions — no manual AWS console clicks required after initial setup.

---

### AWS Resources Created by Terraform

```
AWS Account (us-east-1)
│
├── S3 Bucket  (created manually — state backend for Terraform)
│   └── zen-pharma-terraform-state-<your-username>
│       ├── envs/dev/terraform.tfstate
│       ├── envs/qa/terraform.tfstate
│       └── envs/prod/terraform.tfstate
│
├── VPC  (10.0.0.0/16)
│   ├── Public Subnets        10.0.1.0/24  (us-east-1a)  ]  NAT Gateway,
│   │                         10.0.2.0/24  (us-east-1b)  ]  NLB, Ingress
│   ├── Private EKS Subnets   10.0.3.0/24  (us-east-1a)  ]  EKS worker
│   │                         10.0.4.0/24  (us-east-1b)  ]  nodes (private)
│   └── Private RDS Subnets   10.0.5.0/24  (us-east-1a)  ]  RDS PostgreSQL
│                             10.0.6.0/24  (us-east-1b)  ]  (private)
│
├── EKS Cluster  (pharma-dev-cluster, Kubernetes 1.33)
│   ├── Managed Node Group
│   │   ├── Instance type : t3.small
│   │   ├── Desired       : 3 nodes
│   │   ├── Min / Max     : 1 / 4
│   │   └── Subnets       : private EKS subnets (no public IP)
│   └── OIDC Provider
│       └── Enables IRSA — pods assume IAM roles without static credentials
│
├── RDS PostgreSQL  (pharma-dev-postgres)
│   ├── Engine        : PostgreSQL 15.7
│   ├── Instance      : db.t3.micro
│   ├── Storage       : 20 GB gp2, encrypted
│   ├── Access        : private subnet only, port 5432 from EKS SG only
│   └── DB name       : pharmadb  /  Master user: pharmaadmin
│
├── ECR Repositories  (8 repos, one per service)
│   ├── api-gateway               (Spring Cloud Gateway, port 8080)
│   ├── auth-service              (JWT auth, port 8081)
│   ├── drug-catalog-service      (drug catalogue, port 8082)
│   ├── inventory-service         (stock management, port 8083)
│   ├── supplier-service          (vendor management, port 8084)
│   ├── manufacturing-service     (batch tracking, port 8085)
│   ├── notification-service      (Node.js, port 3000)
│   └── pharma-ui                 (React frontend, port 80)
│   │
│   └── Each repo has:
│       ├── scan_on_push = true   (automatic CVE scan on every push)
│       └── Lifecycle policy      (keep last 10 images, expire older ones)
│
├── IAM
│   ├── EKS Cluster Role          (allows EKS control plane to manage AWS resources)
│   ├── EKS Node Group Role       (allows worker nodes to pull from ECR, join cluster)
│   │
│   ├── GitHub Actions OIDC Role  (pharma-dev-gitlab-runner-role)
│   │   ├── Trust policy : repo zen-pharma-frontend and zen-pharma-backend only
│   │   └── Permissions  : ECR push/pull, EKS describe
│   │   └── How it works : GitHub OIDC token -> AWS STS -> short-lived credentials
│   │                      No AWS_ACCESS_KEY_ID stored in GitHub
│   │
│   ├── ESO IRSA Role             (pharma-dev-eso-role)
│   │   ├── Trust policy : EKS service account external-secrets/external-secrets
│   │   └── Permissions  : secretsmanager:GetSecretValue on /pharma/* paths only
│   │
│   └── ArgoCD IRSA Role          (pharma-dev-argocd-role)
│       └── Trust policy : EKS service account argocd/argocd-application-controller
│
└── AWS Secrets Manager
    ├── /pharma/dev/db-credentials   {"username": "pharmaadmin", "password": "..."}
    └── /pharma/dev/jwt-secret       {"secret": "..."}
```

---

### Terraform Module Structure

```
zen-infra/
├── envs/
│   ├── dev/    <-- calls all modules with dev-specific values
│   ├── qa/     <-- same modules, different sizing
│   └── prod/   <-- same modules, production sizing + HA settings
│
└── modules/
    ├── vpc/            creates VPC, subnets, IGW, NAT GW, route tables
    ├── eks/            creates EKS cluster, node group, OIDC provider
    ├── rds/            creates RDS instance, subnet group, security group
    ├── ecr/            creates ECR repos with lifecycle policies
    ├── iam/            creates OIDC roles for GitHub Actions, ESO, ArgoCD
    └── secrets-manager/ stores DB password and JWT secret in Secrets Manager
```

Each environment directory (`envs/dev`) calls the modules like functions:

```
envs/dev/main.tf
    |
    |-- module "vpc"              --> modules/vpc/
    |-- module "eks"              --> modules/eks/   (depends on vpc outputs)
    |-- module "rds"              --> modules/rds/   (depends on vpc + eks outputs)
    |-- module "ecr"              --> modules/ecr/
    |-- module "iam"              --> modules/iam/   (depends on eks OIDC outputs)
    └-- module "secrets_manager"  --> modules/secrets-manager/
```

Modules share data via outputs — for example, `module.eks.oidc_provider_arn` is passed
into `module.iam` so the IAM trust policy references the exact OIDC provider created
for this cluster, not a hardcoded ARN.

---

### Network Traffic Flow

```
Internet
    |
    v
AWS Network Load Balancer  (created by NGINX Ingress Controller Helm chart)
    |  routes by URL path
    |-- /          -->  pharma-ui       (React, port 80)
    |-- /api/*     -->  api-gateway     (port 8080)
                           |
                           |-- /api/auth/*          --> auth-service        (8081)
                           |-- /api/catalog/*       --> drug-catalog-svc    (8082)
                           |-- /api/inventory/*     --> inventory-service   (8083)
                           |-- /api/suppliers/*     --> supplier-service    (8084)
                           |-- /api/manufacturing/* --> manufacturing-svc   (8085)
                           └-- /api/notifications/* --> notification-svc    (3000)
                                                            |
                                                    All backend services
                                                    pull secrets from
                                                    AWS Secrets Manager
                                                    via ESO (no passwords
                                                    in pod spec or config)
                                                            |
                                                            v
                                               RDS PostgreSQL (private subnet)
```

---

### GitHub Actions CI/CD Flow for Infrastructure

```
Developer creates feature branch in zen-infra
    |
    v
git push origin feature/my-change
    |
    v
Open Pull Request  -->  zen-infra GitHub Actions runs automatically:
    |
    |   [Terraform Plan job]
    |   1. Checkout code
    |   2. Setup Terraform 1.10.0
    |   3. Configure AWS credentials  (static IAM keys from GitHub Secrets)
    |   4. terraform fmt -check       --> fails if code is not formatted
    |   5. terraform init -backend-config=backend.tfvars  --> connects to S3 backend
    |   6. terraform validate         --> syntax and logic check
    |   7. terraform plan             --> shows what will change (saved as artifact)
    |
    |   Plan output is visible in the Actions tab. PR is blocked if plan fails.
    |
    v
PR reviewed and merged to main
    |
    v
[Terraform Plan job runs again on main - fresh plan]
    |
    v
[Terraform Apply job - PAUSES for manual approval]
    |
    |   Go to: Actions --> running workflow --> "Review deployments" --> Approve
    |
    v
[Terraform Apply runs]
    |   8. terraform apply tfplan     --> provisions/updates AWS resources
    |      (takes 15-25 min for EKS + RDS)
    |
    v
Infrastructure updated in AWS
    |
    v
EKS cluster is ready for Stage 2 (install NGINX Ingress, ArgoCD, ESO)
```

---

### Security Design Decisions

| Decision | Why |
|---|---|
| Worker nodes in private subnets | Nodes not reachable from internet; only NLB is public |
| RDS in private subnets | Database never exposed to internet; only EKS nodes can connect (port 5432 via SG rule) |
| No static AWS keys in GitHub CI | GitHub Actions uses OIDC; credentials are short-lived (1 hour) and scoped to specific repos |
| IRSA for pods | Pods never hold AWS credentials; they exchange a projected K8s token for short-lived STS credentials |
| Secrets Manager (not ConfigMap) | DB passwords and JWT secret never live in Git or Kubernetes config; ESO syncs them at runtime |
| ECR scan on push | Every image is automatically scanned for CVEs when pushed; results visible in ECR console |
| S3 state with versioning | Terraform state is versioned — accidental corruption can be rolled back |

---

## 2. Prerequisites

Ensure the following tools are installed on your local machine before starting.

### Required Tools

| Tool | Minimum Version | Install |
|---|---|---|
| Terraform | 1.10.0+ | https://developer.hashicorp.com/terraform/install |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Git | 2.x | https://git-scm.com/downloads |

### Verify Installations

```bash
terraform version
# Terraform v1.10.x

aws --version
# aws-cli/2.x.x

git --version
# git version 2.x.x
```

### Required Access

- An AWS account with administrator access (or sufficient permissions — see Step 1)
- A GitHub account
- The zen-infra repository forked to your GitHub account

---

## 3. Repository Structure

```
zen-infra/
├── .github/
│   ├── dependabot.yml                    # Automated dependency update config
│   └── workflows/
│       └── terraform.yml                 # CI/CD pipeline — plan + apply + destroy
│
├── envs/
│   ├── dev/
│   │   ├── backend.tf                    # S3 remote state config for dev (bucket + key only)
│   │   ├── backend.tfvars                # Backend region — passed to terraform init
│   │   ├── providers.tf                  # AWS, Kubernetes, TLS provider config
│   │   ├── main.tf                       # Module calls with dev-specific values
│   │   ├── variables.tf                  # Input variable declarations (includes aws_region)
│   │   └── outputs.tf                    # Output values (cluster name, RDS endpoint)
│   ├── qa/                               # QA environment (structure mirrors dev)
│   └── prod/                             # Prod environment (structure mirrors dev)
│
└── modules/
    ├── vpc/                              # VPC, subnets, IGW, NAT Gateway, route tables
    ├── eks/                              # EKS cluster, node group, OIDC provider
    ├── rds/                              # RDS PostgreSQL, subnet group, security group
    ├── ecr/                              # ECR repositories and lifecycle policies
    ├── iam/                              # GitHub Actions OIDC role and policy
    └── secrets-manager/                  # Secrets Manager secrets for app credentials
```

**Key design decisions:**
- **Directory-per-environment** (`envs/dev`, `envs/qa`, `envs/prod`) — complete isolation, separate state files, different resource sizing per environment
- **Shared modules** — all environments call the same modules with different input values
- **No `terraform.tfvars`** — secrets are never stored on disk, passed at runtime from GitHub Secrets

---

## 4. Step 1 — AWS Account Setup

### 4.1 Create an IAM User for Terraform (if not using OIDC)

For the initial bootstrap (before OIDC is set up via Terraform), you need an IAM user with programmatic access.

Go to **AWS Console → IAM → Users → Create user**:
- Username: `terraform-ci`
- Access type: Programmatic access
- Permissions: Attach the following managed policies:
  - `AdministratorAccess` (simplest for learning — scope down in production)

Save the **Access Key ID** and **Secret Access Key** — you will need these in Step 5.

> **Note for production**: Scope IAM permissions to only what Terraform needs — EC2, EKS, RDS, ECR, IAM, Secrets Manager, S3, VPC.

### 4.2 Configure AWS CLI Locally

```bash
aws configure
# AWS Access Key ID: <your-access-key-id>
# AWS Secret Access Key: <your-secret-access-key>
# Default region name: us-east-1
# Default output format: json
```

Verify it works:

```bash
aws sts get-caller-identity
# Should return your account ID, user ARN, and user ID
```

---

## 5. Step 2 — S3 State Backend Setup

Terraform requires an S3 bucket to store its state file. This bucket must exist **before** running Terraform. Create it manually — you only do this once.

### 5.1 Create the S3 Bucket

Replace `YOUR-GITHUB-USERNAME` with your actual GitHub username to make the bucket name unique.

```bash
# Create the bucket
aws s3api create-bucket \
  --bucket zen-pharma-terraform-state-YOUR-GITHUB-USERNAME \
  --region us-east-1

# Enable versioning (allows state rollback)
aws s3api put-bucket-versioning \
  --bucket zen-pharma-terraform-state-YOUR-GITHUB-USERNAME \
  --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
  --bucket zen-pharma-terraform-state-YOUR-GITHUB-USERNAME \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

# Block all public access
aws s3api put-public-access-block \
  --bucket zen-pharma-terraform-state-YOUR-GITHUB-USERNAME \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### 5.2 Verify the Bucket

```bash
aws s3 ls s3://zen-pharma-terraform-state-YOUR-GITHUB-USERNAME
# Should return empty (no error)
```

---

## 6. Step 3 — Fork and Configure the Repository

### 6.1 Fork the Repository

1. Go to `github.com/your-github-username/zen-infra`
2. Click **Fork** (top right)
3. Select your account as the destination
4. Clone your fork locally:

```bash
git clone https://github.com/YOUR-GITHUB-USERNAME/zen-infra.git
cd zen-infra
```

---

## 7. Step 4 — Update Configuration for Your Account

You need to update four files to point to your S3 bucket and GitHub username.

### 7.1 Update Backend Configuration

The backend region is kept out of `backend.tf` (Terraform backend blocks do not support variables). Instead it lives in a `backend.tfvars` file that you pass to `terraform init`.

**Step 1 — update the bucket name in each `backend.tf`:**

**`envs/dev/backend.tf`**
```hcl
terraform {
  backend "s3" {
    bucket       = "zen-pharma-terraform-state-YOUR-GITHUB-USERNAME"
    key          = "envs/dev/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
```

**`envs/qa/backend.tf`** — same change, key stays `envs/qa/terraform.tfstate`

**`envs/prod/backend.tf`** — same change, key stays `envs/prod/terraform.tfstate`

**Step 2 — verify `backend.tfvars` in each env directory:**

Each environment already has a `backend.tfvars` file with the region:

```hcl
# envs/dev/backend.tfvars  (also qa/ and prod/)
region = "us-east-1"
```

Change the value here if you deploy to a different region. This is the **single place** you need to update for the region.

**Step 3 — always pass `backend.tfvars` when initialising Terraform:**

```bash
cd envs/dev
terraform init -backend-config=backend.tfvars
```

> **Why this pattern?** Terraform's `backend` block is evaluated before any variables are loaded, so `var.aws_region` cannot be used there. The `-backend-config` flag injects the region at init time, keeping region in one place without duplicating it in the backend block.

### 7.2 Update GitHub Organisation Variable

In `envs/dev/variables.tf`, update the default value for `github_org`:

```hcl
variable "github_org" {
  description = "GitHub username or organization"
  type        = string
  default     = "YOUR-GITHUB-USERNAME"   # ← change this
}
```

Do the same in `envs/qa/variables.tf` and `envs/prod/variables.tf`.

### 7.3 Update the GitHub Actions Workflow

In `.github/workflows/terraform.yml`, update the `github_org` value:

```yaml
- name: Terraform Plan
  run: |
    terraform plan \
      -var="aws_region=${{ env.AWS_REGION }}" \
      -var="db_password=${{ secrets.DEV_DB_PASSWORD }}" \
      -var="jwt_secret=${{ secrets.DEV_JWT_SECRET }}" \
      -var="github_org=YOUR-GITHUB-USERNAME" \    # ← change this
      -out=tfplan \
      -no-color
```

The `aws_region` var is sourced from the `AWS_REGION` env variable at the top of `terraform.yml` — change it there once to update the region everywhere in CI.

### 7.4 Commit and Push Changes

```bash
git add envs/dev/backend.tf envs/qa/backend.tf envs/prod/backend.tf
git add envs/dev/variables.tf envs/qa/variables.tf envs/prod/variables.tf
git add .github/workflows/terraform.yml
git commit -m "config: update bucket name and github org for my account"
git push origin main
```

---

## 8. Step 5 — GitHub Secrets Setup

The pipeline needs AWS credentials and application secrets to run Terraform. These are stored as encrypted GitHub Secrets — never in code.

### 8.1 Add Repository Secrets

Go to your fork on GitHub:
**Settings → Secrets and variables → Actions → New repository secret**

Add the following secrets:

| Secret Name | Value | Description |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | Your IAM user access key ID | AWS authentication for Terraform |
| `AWS_SECRET_ACCESS_KEY` | Your IAM user secret access key | AWS authentication for Terraform |
| `DEV_DB_PASSWORD` | A strong password (min 8 chars) | RDS PostgreSQL master password |
| `DEV_JWT_SECRET` | A long random string | JWT signing secret for the app |

**Generating a strong random secret:**
```bash
# Generate a random JWT secret
openssl rand -hex 32
```

> **Important**: Once set, these values are never visible again in the GitHub UI. Store them in a password manager.

---

## 9. Step 6 — GitHub Environment Setup

GitHub Environments add an approval gate before `terraform apply` runs. This ensures a human reviews the plan before infrastructure changes are applied.

### 9.1 Create the Dev Environment

Go to your fork on GitHub:
**Settings → Environments → New environment**

- Name: `dev`
- Click **Configure environment**

### 9.2 Add Required Reviewer

Under **Deployment protection rules**:
- Check **Required reviewers**
- Search for and add your GitHub username
- Leave **Prevent self-review** unchecked (you are a solo learner)
- Click **Save protection rules**

### 9.3 What This Does

When the pipeline runs after a merge to `main`:
1. The `plan` job runs automatically
2. The `apply` job starts but **pauses** — GitHub shows a "Review deployments" button
3. You review the plan in the Actions logs
4. You click **Approve and deploy**
5. `terraform apply` runs

This prevents accidental infrastructure changes — even if bad code merges to main, a human must approve before anything changes in AWS.

---

## 10. Step 7 — Provision Infrastructure via Pipeline

With everything configured, you are ready to provision the infrastructure.

### 10.1 Create a Feature Branch

Never push directly to main for infrastructure changes. Use a PR:

```bash
git checkout -b feature/initial-setup
```

Make a small change to trigger the pipeline — for example, add a comment to `envs/dev/main.tf`:

```hcl
# Initial dev environment setup
data "aws_caller_identity" "current" {}
```

```bash
git add envs/dev/main.tf
git commit -m "feat: initial dev environment setup"
git push origin feature/initial-setup
```

### 10.2 Open a Pull Request

Go to your fork on GitHub and open a PR from `feature/initial-setup` → `main`.

The **Terraform Plan** job will run automatically. After a few minutes, check the Actions tab to see the plan output. Verify:
- `Plan: X to add, 0 to change, 0 to destroy`
- No unexpected changes or errors

### 10.3 Merge the PR

Once the plan looks correct, merge the PR. This triggers the pipeline on `main`:

1. **Plan job** runs again (fresh plan on merge)
2. **Apply job** starts and **pauses** for approval
3. Go to **Actions → the running workflow → Review deployments**
4. Click **Approve and deploy**

### 10.4 Wait for Apply to Complete

The apply will take **15–25 minutes** because:
- EKS cluster creation: ~10 minutes
- EKS node group provisioning: ~5 minutes
- RDS instance creation: ~5 minutes

Do not cancel the job — a cancelled mid-apply leaves partial state.

Monitor progress in **Actions → the running workflow → Terraform Apply step**.

---

## 11. Step 8 — Verify the Infrastructure

After apply completes, verify everything was created correctly.

### 11.1 Check Terraform Outputs

The apply job logs will show outputs at the end:

```
Apply complete! Resources: 45 added, 0 changed, 0 destroyed.

Outputs:

eks_cluster_name = "pharma-dev-cluster"
rds_endpoint     = "pharma-dev-postgres.xxxxxxxx.us-east-1.rds.amazonaws.com"
```

### 11.2 Verify in AWS Console

**EKS:**
- Go to **AWS Console → EKS → Clusters**
- Verify `pharma-dev-cluster` is `Active`
- Click the cluster → **Compute** tab → verify node group shows 3 nodes `Ready`

**RDS:**
- Go to **AWS Console → RDS → Databases**
- Verify `pharma-dev-postgres` is `Available`

**ECR:**
- Go to **AWS Console → ECR → Repositories**
- Verify 5 repositories exist: `api-gateway`, `auth-service`, `pharma-ui`, `notification-service`, `drug-catalog-service`

**Secrets Manager:**
- Go to **AWS Console → Secrets Manager**
- Verify `/pharma/dev/db-credentials` and `/pharma/dev/jwt-secret` exist

### 11.3 Connect to the EKS Cluster Locally

```bash
# Update local kubeconfig
aws eks update-kubeconfig \
  --region us-east-1 \
  --name pharma-dev-cluster

# Verify connection
kubectl get nodes
# Should show 3 nodes in Ready state

kubectl get namespaces
# Should show default, kube-system, kube-public, kube-node-lease
```

---

## 12. Infrastructure Details

### 12.1 Networking

| Resource | Value | Purpose |
|---|---|---|
| VPC CIDR | `10.0.0.0/16` | Main network |
| Public Subnet 1 | `10.0.1.0/24` (us-east-1a) | NAT Gateway, Load Balancers |
| Public Subnet 2 | `10.0.2.0/24` (us-east-1b) | NAT Gateway, Load Balancers |
| Private EKS Subnet 1 | `10.0.3.0/24` (us-east-1a) | EKS worker nodes |
| Private EKS Subnet 2 | `10.0.4.0/24` (us-east-1b) | EKS worker nodes |
| Private RDS Subnet 1 | `10.0.5.0/24` (us-east-1a) | RDS PostgreSQL |
| Private RDS Subnet 2 | `10.0.6.0/24` (us-east-1b) | RDS PostgreSQL |

Worker nodes and RDS are in private subnets — no direct internet access. Outbound traffic routes through the NAT Gateway.

### 12.2 EKS Cluster

| Setting | Dev Value | Notes |
|---|---|---|
| Cluster version | 1.33 | Update periodically |
| Node instance type | t3.small | Cost-optimised for dev |
| Desired nodes | 3 | Adjust based on workload |
| Min nodes | 2 | Minimum for HA |
| Max nodes | 4 | Auto-scaling ceiling |
| OIDC provider | Enabled | Required for IRSA |

### 12.3 RDS PostgreSQL

| Setting | Dev Value | Prod Value |
|---|---|---|
| Engine version | 15.7 | 15.7 |
| Instance class | db.t3.micro | Larger (db.t3.medium+) |
| Storage | 20 GB gp2 | More, with autoscaling |
| Multi-AZ | No | Yes |
| Backup retention | 0 days | 7 days |
| Deletion protection | No | Yes |
| Encryption | Yes | Yes |
| Public access | No | No |

RDS is only accessible from EKS worker nodes via the security group — port 5432 from the EKS cluster security group only.

### 12.4 ECR Repositories

All 5 repositories have:
- `image_tag_mutability = MUTABLE` — allows overwriting tags (useful in dev)
- `scan_on_push = true` — automatic vulnerability scanning on every push
- Lifecycle policy: keep last 10 images, expire older ones automatically

### 12.5 GitHub Actions OIDC

The IAM module creates a GitHub Actions OIDC role that allows CI/CD pipelines in `zen-pharma-frontend` and `zen-pharma-backend` to push images to ECR **without storing AWS credentials in GitHub Secrets**.

How it works:
1. GitHub mints a short-lived OIDC token per workflow run
2. The workflow calls `aws-actions/configure-aws-credentials` with the role ARN
3. AWS validates the token and issues temporary STS credentials (1 hour)
4. CI uses these credentials to push images to ECR

The role is restricted to:
- Only `YOUR-GITHUB-USERNAME/zen-pharma-frontend` and `YOUR-GITHUB-USERNAME/zen-pharma-backend` repos
- Only `main` and `develop` branches

---

## 13. Day-2 Operations

### Making Infrastructure Changes

Always use the PR-based flow:

```bash
# 1. Create a branch
git checkout -b feature/your-change

# 2. Make your Terraform changes
# Edit files in envs/dev/ or modules/

# 3. Test locally first
cd envs/dev
terraform init -backend-config=backend.tfvars
terraform plan \
  -var="aws_region=us-east-1" \
  -var="db_password=test" \
  -var="jwt_secret=test"

# 4. Push and open a PR
git add .
git commit -m "describe your change"
git push origin feature/your-change
# Open PR on GitHub → plan runs automatically

# 5. Review the plan in Actions logs
# 6. Merge if plan is correct → approve apply
```

### Scaling the EKS Node Group

Edit `envs/dev/main.tf`:

```hcl
module "eks" {
  ...
  desired_capacity = 5    # ← change this
  min_size         = 3
  max_size         = 8
}
```

Open a PR, review the plan (should show EKS node group update), merge, approve apply.

### Adding a New ECR Repository

Edit `envs/dev/main.tf`:

```hcl
module "ecr" {
  ...
  repositories = [
    "api-gateway",
    "auth-service",
    "pharma-ui",
    "notification-service",
    "drug-catalog-service",
    "new-service"            # ← add here
  ]
}
```

Plan will show 2 new resources: `aws_ecr_repository.main["new-service"]` and its lifecycle policy.

### Checking State

```bash
cd envs/dev

# List all resources in state
terraform state list

# Inspect a specific resource
terraform state show module.eks.aws_eks_cluster.main

# Check for drift (what changed in AWS outside Terraform)
terraform plan \
  -var="aws_region=us-east-1" \
  -var="db_password=dummy" \
  -var="jwt_secret=dummy"
```

---

## 14. Destroying Infrastructure

> **Warning**: This permanently deletes all infrastructure including the EKS cluster, RDS database, and all data. There is no undo.

### Via Pipeline (Recommended)

1. Go to your fork on GitHub → **Actions**
2. Select **Terraform Infrastructure** workflow
3. Click **Run workflow**
4. Set:
   - **Terraform action**: `destroy`
   - **Type "destroy" to confirm**: `destroy`
5. Click **Run workflow**
6. The destroy job will pause for approval — review then approve
7. Wait 15–25 minutes for all resources to be deleted

### Locally (Alternative)

```bash
cd envs/dev
terraform init -backend-config=backend.tfvars
terraform destroy \
  -var="aws_region=us-east-1" \
  -var="db_password=dummy" \
  -var="jwt_secret=dummy" \
  -var="github_org=YOUR-GITHUB-USERNAME"
```

Type `yes` when prompted.

### After Destroying

The S3 state bucket is **not** deleted by Terraform destroy — it is managed separately. To delete it:

```bash
# Empty the bucket first
aws s3 rm s3://zen-pharma-terraform-state-YOUR-GITHUB-USERNAME --recursive

# Delete the bucket
aws s3api delete-bucket \
  --bucket zen-pharma-terraform-state-YOUR-GITHUB-USERNAME \
  --region us-east-1
```

---

## 15. Troubleshooting

### Plan shows resources already exist (RepositoryAlreadyExistsException)

ECR repositories cannot be destroyed if they contain images. If you recreated the stack after a destroy, images may still exist in the repos.

**Fix — delete repos manually then re-run:**
```bash
for repo in api-gateway auth-service pharma-ui notification-service drug-catalog-service; do
  aws ecr delete-repository \
    --repository-name $repo \
    --force \
    --region us-east-1
done
```

Then re-trigger the pipeline.

### Apply failed halfway through

Do not panic. Terraform updates state for every resource it successfully creates.

1. Read the error in the Actions logs (expand the Apply step, scroll up from the bottom)
2. Fix the root cause
3. Re-trigger the pipeline — it will continue from where it left off

### State lock error

```
Error: Error acquiring the state lock
```

Another apply is running (or a previous one crashed mid-run). Wait for it to finish. If you are certain no apply is running:

```bash
cd envs/dev
terraform force-unlock <LOCK-ID>
# Lock ID is shown in the error message
```

### `terraform init` fails — region not configured

If you see `No valid credential sources found` or a region error during init, you likely forgot the `-backend-config` flag:

```bash
terraform init -backend-config=backend.tfvars
```

The `backend.tfvars` file in each env directory holds the region. Without it, Terraform has no region for the S3 backend.

### `terraform init` fails — bucket does not exist

You have not created the S3 bucket yet. Follow [Step 2](#5-step-2--s3-state-backend-setup).

### EKS nodes not joining the cluster

```bash
kubectl get nodes
# Shows nodes in NotReady state
```

Check node group IAM role has the required policies:
- `AmazonEKSWorkerNodePolicy`
- `AmazonEKS_CNI_Policy`
- `AmazonEC2ContainerRegistryReadOnly`

These are attached automatically by Terraform. If nodes are not joining, the apply may not have completed fully — check the apply logs.

### Pipeline apply job is skipped

The apply job only runs on:
- Push/merge to `main` when `envs/dev/**` or `modules/**` files changed
- Manual `workflow_dispatch` with `action: apply`

If you only changed workflow files (`.github/workflows/`), the `paths` filter prevents the pipeline from triggering.

### Cannot connect to EKS cluster locally

```bash
# Re-fetch credentials
aws eks update-kubeconfig --region us-east-1 --name pharma-dev-cluster

# Check your AWS identity
aws sts get-caller-identity

# Verify cluster is active
aws eks describe-cluster --name pharma-dev-cluster --query 'cluster.status'
```

Only the IAM entity that created the cluster (the CI/CD role or your local user) has access by default. If using a different IAM user locally, you need to add it to the EKS aws-auth ConfigMap.

---

## Cost Estimate (Dev Environment)

| Resource | Approximate Cost |
|---|---|
| EKS Cluster | ~$0.10/hour (~$72/month) |
| 3x t3.small EC2 nodes | ~$0.06/hour (~$43/month) |
| RDS db.t3.micro | ~$0.02/hour (~$14/month) |
| NAT Gateway | ~$0.045/hour (~$32/month) + data transfer |
| ECR Storage | ~$0.10/GB/month (minimal) |
| Secrets Manager | ~$0.40/secret/month (2 secrets = ~$0.80) |
| **Total estimate** | **~$160–180/month** |

> **Tip for learners**: Destroy the infrastructure when not in use. EKS and NAT Gateway are the largest costs. Use the destroy pipeline at the end of each day and re-provision when needed.

---

*This guide covers the dev environment. QA and prod environments follow the same setup process — create the GitHub environments with appropriate protection rules and add the corresponding secrets (`QA_DB_PASSWORD`, `QA_JWT_SECRET`, etc.).*

---

## 16. Interview Preparation

After completing this lab you have built and deployed real infrastructure — not watched a demo. Dedicated interview preparation documents are available in the `docs/` folder:

- [Terraform Interview Questions](docs/terraform-interview-questions.md) — 40 questions covering core concepts, state management, modules, CI/CD pipeline, and real-world scenarios with zen-infra references
- GitHub Actions Interview Questions — coming soon

---

*Built with Terraform 1.10+ · GitHub Actions · AWS EKS, RDS, ECR, VPC, IAM, Secrets Manager*
