# 🏗️ zen-infra — Complete Implementation Guide (Layman's Edition)

> **What is this repo?**  
> Think of **zen-infra** as a **blueprint + robot** combo for building an entire cloud data centre on AWS.  
> The blueprint is written in **Terraform** (Infrastructure-as-Code), and the robot is **GitHub Actions** (an automated pipeline).  
> You describe *what* you want (EKS, RDS, VPC…) and the robot *builds it* on AWS automatically.

---

## 🗺️ Big Picture — What Gets Built

```
Your Computer (just Git + a browser)
        │  push code
        ▼
GitHub Repository (zen-infra)
        │  GitHub Actions CI/CD pipeline triggers
        ▼
AWS Cloud  (us-east-1)
  ├── VPC          ← the "private office building" (network boundary)
  ├── EKS Cluster  ← the Kubernetes "server farm" that runs your app
  ├── RDS Postgres ← the database (locked inside the private office)
  ├── ECR Repos    ← Docker image registry (like DockerHub but private)
  ├── IAM Roles    ← security ID badges / access cards
  ├── Secrets Mgr  ← a safe vault for passwords
  └── Karpenter    ← auto-scaler that adds/removes servers on demand
```

---

## 🧩 Concepts Explained Simply

| Term | What it Really Is |
|------|------------------|
| **Terraform** | A recipe file that says "create X servers, Y databases" — AWS reads it and builds everything |
| **Module** | A reusable Lego brick (e.g., "vpc" module = one VPC brick) |
| **Environment (dev/qa/prod)** | Same Lego set, different sizes/configs for each stage |
| **S3 Backend** | A shared notebook in the cloud that remembers *what Terraform already built* (state file) |
| **GitHub Actions** | A robot that runs your Terraform commands whenever you push code |
| **EKS** | AWS-managed Kubernetes — a platform for running Docker containers at scale |
| **OIDC / IRSA** | Passwordless auth — pods/GitHub prove who they are with a signed token, no static passwords |
| **Karpenter** | Smart auto-scaler that picks the right EC2 size and spins it up/down automatically |
| **ESO** | External Secrets Operator — pulls secrets from AWS Secrets Manager into Kubernetes pods |
| **ArgoCD** | GitOps tool — keeps Kubernetes apps in sync with a Git repo automatically |

---

## 📁 Repository Structure (with annotations)

```
zen-infra/
│
├── .github/
│   └── workflows/
│       └── terraform.yml      ← THE ROBOT: CI/CD pipeline (plan/apply/destroy)
│
├── envs/                      ← Environment-specific configs (call the modules)
│   ├── dev/
│   │   ├── backend.tf         ← Where to store Terraform's memory (S3 bucket)
│   │   ├── providers.tf       ← What cloud/tools Terraform talks to (AWS, helm, kubectl)
│   │   ├── main.tf            ← CALLS all modules with dev-specific values
│   │   ├── variables.tf       ← Input values (region, passwords, etc.)
│   │   └── outputs.tf         ← Values to display after apply (cluster name, endpoint)
│   ├── qa/                    ← Same structure, QA sizing
│   └── prod/                  ← Same structure, production sizing
│
├── modules/                   ← THE LEGO BRICKS (reusable infra logic)
│   ├── vpc/                   ← Network: VPC, subnets, NAT, IGW, route tables
│   ├── eks/                   ← Kubernetes cluster + node group + OIDC
│   ├── rds/                   ← PostgreSQL database
│   ├── ecr/                   ← Docker image repositories (8 per env)
│   ├── iam/                   ← IAM roles for ESO, ArgoCD, GitLab Runner
│   ├── secrets-manager/       ← Stores DB password + JWT secret in AWS vault
│   └── karpenter/             ← Auto-scaler setup (NodeClass, NodePool, Helm)
│
├── scripts/
│   ├── 01-install-prerequisites.sh   ← Install tools (kubectl, helm, argocd CLI)
│   ├── 02-bootstrap-argocd.sh        ← Install ArgoCD on the cluster
│   ├── 03-setup-external-secrets.sh  ← Install ESO + connect to Secrets Manager
│   └── 04-verify-deployment.sh       ← Sanity-check: is everything running?
│
├── docs/
│   ├── architecture.jpg              ← Visual architecture diagram
│   ├── FULL-DEPLOYMENT-GUIDE.md      ← Detailed step-by-step (official)
│   └── CICD-IMPLEMENTATION.md        ← CI/CD deep dive
│
├── ASSIGNMENT.md              ← Rubric (what gets marked and how)
├── IRSA.md                    ← Explanation of IRSA (IAM Roles for Service Accounts)
└── README.md                  ← Full setup guide
```

---

## 🚦 PHASE-BY-PHASE IMPLEMENTATION PLAN

---

### ✅ PHASE 0 — Prerequisites (Do This First!)

**Goal:** Install all tools and verify your AWS access.

#### Step 0.1 — Install Tools

| Tool | Minimum Version | Why |
|------|----------------|-----|
| Terraform | >= 1.10.0 | The IaC engine |
| AWS CLI | >= 2.x | Talks to AWS |
| kubectl | Latest stable | Talks to Kubernetes |
| Helm | >= 3.x | Installs Kubernetes apps (ArgoCD, ESO) |
| Git | Any | Version control |

```bash
# Verify each tool is installed:
terraform --version
aws --version
kubectl version --client
helm version
```

#### Step 0.2 — AWS Account Setup

```bash
# Configure AWS CLI with your credentials:
aws configure
# Enter: Access Key ID, Secret Access Key, Region (us-east-1), Output (json)

# Verify it works:
aws sts get-caller-identity
# Should return your AWS Account ID and IAM user ARN
```

> [!IMPORTANT]
> You need **AdministratorAccess** (or equivalent) on your AWS account for Terraform to create all resources.

---

### ✅ PHASE 1 — S3 State Backend Setup

**Goal:** Create the "shared notebook" where Terraform remembers what it built.

**Think of it like:** A Google Doc that Terraform uses to track which resources it owns. Without this, Terraform would "forget" what it created.

#### Step 1.1 — Create S3 Bucket

```bash
# Replace <your-username> with your GitHub username:
aws s3api create-bucket \
  --bucket zen-pharma-terraform-state-<your-username> \
  --region us-east-1

# Enable versioning (so you can recover from accidents):
aws s3api put-bucket-versioning \
  --bucket zen-pharma-terraform-state-<your-username> \
  --versioning-configuration Status=Enabled

# Enable encryption at rest:
aws s3api put-bucket-encryption \
  --bucket zen-pharma-terraform-state-<your-username> \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Block all public access (CRITICAL security step):
aws s3api put-public-access-block \
  --bucket zen-pharma-terraform-state-<your-username> \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

#### Step 1.2 — Update backend.tf in All Environments

Edit these three files and replace the bucket name with YOUR bucket:

- `envs/dev/backend.tf`
- `envs/qa/backend.tf`
- `envs/prod/backend.tf`

```hcl
# envs/dev/backend.tf
terraform {
  backend "s3" {
    bucket       = "zen-pharma-terraform-state-<your-username>"  # CHANGE THIS
    key          = "envs/dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true  # S3 native locking (requires Terraform >= 1.10)
  }
}
```

> [!NOTE]
> Each environment uses a **different key** (path inside the bucket):
> - dev  -> `envs/dev/terraform.tfstate`
> - qa   -> `envs/qa/terraform.tfstate`
> - prod -> `envs/prod/terraform.tfstate`

---

### ✅ PHASE 2 — Fork & Configure the Repository

**Goal:** Get your own copy of the code and wire up your GitHub settings.

#### Step 2.1 — Fork the Repository

1. Go to the original zen-infra repo on GitHub
2. Click **Fork** (top-right)
3. Clone YOUR fork locally:

```bash
git clone https://github.com/<your-username>/zen-infra.git
cd zen-infra
```

#### Step 2.2 — Create IAM User for GitHub Actions

> [!IMPORTANT]
> This is a temporary IAM user with static credentials used ONLY to bootstrap the pipeline.

```bash
# Create an IAM user for CI/CD:
aws iam create-user --user-name github-actions-terraform

# Attach AdministratorAccess (tighten later):
aws iam attach-user-policy \
  --user-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

# Create access keys and SAVE the output:
aws iam create-access-key --user-name github-actions-terraform
# COPY the AccessKeyId and SecretAccessKey — you'll need them in Step 3
```

---

### ✅ PHASE 3 — GitHub Secrets & Variables Setup

**Goal:** Give GitHub Actions the credentials and config it needs.

#### Step 3.1 — Add Secrets

Go to: **GitHub repo → Settings → Secrets and variables → Actions → New repository secret**

| Secret Name | Value |
|-------------|-------|
| `AWS_ACCESS_KEY_ID` | AccessKeyId from Step 2.2 |
| `AWS_SECRET_ACCESS_KEY` | SecretAccessKey from Step 2.2 |
| `DEV_DB_PASSWORD` | Strong password for dev DB (e.g., `Dev@SecurePass123!`) |
| `DEV_JWT_SECRET` | Random string for JWT signing |
| `QA_DB_PASSWORD` | Strong password for QA DB |
| `QA_JWT_SECRET` | Random string for QA JWT |
| `PROD_DB_PASSWORD` | Strong password for prod DB |
| `PROD_JWT_SECRET` | Random string for prod JWT |

#### Step 3.2 — Add Variables (not secrets)

Go to: **GitHub repo → Settings → Secrets and variables → Actions → Variables**

| Variable Name | Value |
|---------------|-------|
| `TF_STATE_BUCKET` | `zen-pharma-terraform-state-<your-username>` |
| `GH_ORG` | Your GitHub username or org name |

---

### ✅ PHASE 4 — GitHub Environment Setup (Approval Gates)

**Goal:** Set up "doormen" that must approve before Terraform Apply runs.

**Think of it like:** A two-person rule at a bank vault — one person can't open it alone.

#### Step 4.1 — Create GitHub Environments

Go to: **GitHub repo → Settings → Environments → New environment**

Create three environments:

| Environment Name | Required Reviewers | Protection Rules |
|-----------------|-------------------|-----------------|
| `dev` | Add yourself | Required reviewers |
| `qa` | Add yourself | Required reviewers |
| `prod` | Add yourself | Required reviewers |

> [!TIP]
> When `terraform apply` runs, GitHub Actions will **pause** and email you for approval. Only after you click **Approve** will infrastructure be created.

---

### ✅ PHASE 5 — Branch Protection

**Goal:** Prevent anyone from pushing directly to `main`.

Go to: **GitHub repo → Settings → Branches → Add branch protection rule**

Settings:
- Branch name pattern: `main`
- [x] Require a pull request before merging
- [x] Require at least 1 approving review
- [x] Dismiss stale pull request approvals when new commits are pushed
- [x] Do not allow bypassing the above settings

---

### ✅ PHASE 6 — First Infrastructure Deploy (dev environment)

**Goal:** Actually build the AWS infrastructure using the pipeline.

#### Step 6.1 — Create a Feature Branch

```bash
git checkout -b feature/initial-setup
```

#### Step 6.2 — Verify / Update Configuration

Check these values in `envs/dev/main.tf`:

| Setting | Current Value | Notes |
|---------|--------------|-------|
| `cluster_version` | `1.35` | OK to leave as-is |
| `node_instance_type` | `t3.small` | OK for dev |
| `desired_capacity` | `4` | Can reduce to `2` for cost savings |
| `db_password` | `var.db_password` | Comes from GitHub Secret OK |

#### Step 6.3 — Push & Open Pull Request

```bash
git add .
git commit -m "feat: initial dev environment setup"
git push origin feature/initial-setup
```

Then open a Pull Request on GitHub targeting `main`.

The pipeline will automatically run:
1. `terraform fmt -check` — checks code formatting
2. `terraform init` — downloads Terraform providers
3. `terraform validate` — checks syntax
4. `terraform plan` — shows what will be created (no actual changes yet)

#### Step 6.4 — Review Plan Output

In the GitHub Actions tab, open the **Plan** job and review:
- How many resources will be **added** (should be ~60-80 for fresh deploy)
- No unexpected **destroy** operations

#### Step 6.5 — Merge PR & Approve Apply

1. Get the PR approved by a reviewer
2. Merge the PR to `main`
3. GitHub Actions automatically runs a fresh plan, then **pauses** for approval
4. Go to **Actions → running workflow → Review deployments → Approve**
5. `terraform apply` runs — **this takes 15-25 minutes**

> [!WARNING]
> EKS cluster creation takes ~10 minutes. RDS creation takes ~5 minutes. Total: expect 20-30 minutes.

---

### ✅ PHASE 7 — Verify Infrastructure

**Goal:** Confirm everything was created correctly.

```bash
# Update your local kubeconfig to point at the new cluster:
aws eks update-kubeconfig \
  --region us-east-1 \
  --name pharma-dev-cluster

# Check nodes are Ready:
kubectl get nodes

# Check all system pods are Running:
kubectl get pods -A

# Verify ECR repos exist:
aws ecr describe-repositories --region us-east-1 --query 'repositories[].repositoryName'

# Verify RDS is available:
aws rds describe-db-instances \
  --region us-east-1 \
  --query 'DBInstances[].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}'

# Verify Secrets Manager secrets:
aws secretsmanager list-secrets \
  --region us-east-1 \
  --query 'SecretList[].Name'
```

---

### ✅ PHASE 8 — Stage 2: Install Kubernetes Add-ons

**Goal:** Install the tools that run *inside* Kubernetes (ArgoCD, ESO, NGINX Ingress).

#### Step 8.1 — Install Prerequisites

```bash
bash scripts/01-install-prerequisites.sh
```

This installs: `kubectl`, `helm`, `argocd` CLI, `kubectx`, `kubens`

#### Step 8.2 — Bootstrap ArgoCD

```bash
bash scripts/02-bootstrap-argocd.sh
```

What this does:
- Creates `argocd` namespace
- Installs ArgoCD via Helm
- Configures IRSA for ArgoCD (so it can pull from your private GitHub repos)
- Prints the initial admin password

#### Step 8.3 — Setup External Secrets Operator (ESO)

```bash
bash scripts/03-setup-external-secrets.sh
```

What this does:
- Creates `external-secrets` namespace
- Installs ESO via Helm
- Creates a `ClusterSecretStore` pointing to your AWS Secrets Manager
- Tests the connection

#### Step 8.4 — Verify Everything

```bash
bash scripts/04-verify-deployment.sh
```

---

### ✅ PHASE 9 — Deploy QA Environment

**Goal:** Replicate dev for QA with different sizing.

```bash
git checkout -b feature/qa-environment
# Make QA-specific changes in envs/qa/ if needed
git push origin feature/qa-environment
# Open PR -> merge -> approve apply -> QA infra built
```

Or via `workflow_dispatch` in GitHub Actions:
- Select environment: `qa`
- Select action: `apply`

---

### ✅ PHASE 10 — Deploy Prod Environment

**Goal:** Production-grade infrastructure with HA settings.

> [!CAUTION]
> Production resources cost significantly more. Ensure you have budget approved before applying.

Via `workflow_dispatch` in GitHub Actions:
- Select environment: `prod`
- Select action: `apply`

---

### ✅ PHASE 11 — Day-2 Operations

**Goal:** Ongoing maintenance tasks.

#### Scaling the Cluster

Karpenter auto-scales based on pod demand. You can also check manually:

```bash
# View current node pools:
kubectl get nodepools

# View current nodes and their types:
kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type
```

#### Updating Kubernetes Version

1. Update `cluster_version` in `envs/dev/main.tf`
2. Open PR -> pipeline runs plan -> review -> merge -> approve apply
3. EKS upgrade takes ~10 min per version increment

#### Rotate Secrets

1. Update secret value in GitHub Secrets
2. Run `workflow_dispatch` with `plan` then `apply`
3. New secret is pushed to AWS Secrets Manager
4. ESO syncs to Kubernetes pods automatically

---

### ✅ PHASE 12 — Destroy Infrastructure (When Done)

> [!CAUTION]
> **IRREVERSIBLE** — This deletes everything. Use only when you're done with the project.

Via `workflow_dispatch` in GitHub Actions:
- Select environment: `dev`
- Select action: `destroy`
- In the confirmation box: type the word `destroy` exactly

---

## 🔐 Security Summary

| What | Why It's Secure |
|------|----------------|
| Worker nodes in **private subnets** | Can't be reached directly from internet |
| RDS in **private RDS subnet** | Database never exposed; only EKS security group can connect |
| **No static AWS keys in pods** | IRSA = pods get short-lived tokens, not passwords |
| **OIDC for GitHub Actions** | CI/CD gets temporary credentials, not stored secrets |
| **Secrets Manager** | Passwords never live in Git or Kubernetes YAML files |
| **ECR scan on push** | Every Docker image is scanned for vulnerabilities automatically |
| **S3 state versioning** | Terraform state is backed up; accidents are recoverable |

---

## 🧰 Module Reference

### VPC Module (`modules/vpc/`)
Creates: VPC, 2 public subnets, 2 private EKS subnets, 2 private RDS subnets, Internet Gateway, NAT Gateway, route tables.

### EKS Module (`modules/eks/`)
Creates: EKS control plane, managed node group, OIDC provider.
Key outputs: `cluster_endpoint`, `cluster_name`, `oidc_provider_arn` → passed to IAM & Karpenter modules.

### RDS Module (`modules/rds/`)
Creates: RDS PostgreSQL 15.x, subnet group, security group (port 5432 from EKS SG only), encryption enabled.

### ECR Module (`modules/ecr/`)
Creates: 8 (or 9 in dev) ECR repos. Each has `scan_on_push=true` and a lifecycle policy keeping last 10 images.

### IAM Module (`modules/iam/`)
Creates: 3 IRSA roles (ESO, ArgoCD, GitLab Runner). Uses OIDC trust policies — no static credentials anywhere.

### Secrets Manager Module (`modules/secrets-manager/`)
Creates: `/pharma/<env>/db-credentials` and `/pharma/<env>/jwt-secret` in AWS Secrets Manager.

### Karpenter Module (`modules/karpenter/`)
Creates: Karpenter IRSA role, installs Karpenter via Helm, creates EC2NodeClass and NodePool CRDs.

---

## 📋 Full Checklist (Assignment Rubric Map)

| # | Requirement | Phase | Done? |
|---|-------------|-------|-------|
| 1 | Protected main branch | Phase 5 | [ ] |
| 2 | All changes via PR | Phase 6 | [ ] |
| 3 | Apply only from main | Built into workflow | [ ] |
| 4 | Three environments (dev/qa/prod) | Already exists | [ ] |
| 5 | Reusable Terraform modules | Already exists | [ ] |
| 6 | Remote state with S3 backend | Phase 1 | [ ] |
| 7 | Consistent resource tagging | Built into modules | [ ] |
| 8 | VPC with public/private subnets | Phase 6 | [ ] |
| 9 | EKS cluster with managed node group | Phase 6 | [ ] |
| 10 | RDS PostgreSQL in private subnet | Phase 6 | [ ] |
| 11 | ECR repositories (8 services) | Phase 6 | [ ] |
| 12 | IAM roles with least-privilege | Phase 6 | [ ] |
| 13 | AWS Secrets Manager | Phase 6 | [ ] |
| 14 | terraform fmt + validate on every run | Built into workflow | [ ] |
| 15 | Plan on every PR | Built into workflow | [ ] |
| 16 | Save plan artifact and reuse for apply | Built into workflow | [ ] |
| 17 | Manual approval gate before apply | Phase 4 | [ ] |
| 18 | Manual approval gate before destroy | Phase 4 | [ ] |
| 19 | Prevent concurrent runs | Built into workflow | [ ] |
| 20 | Path-based pipeline triggers (Bonus) | Built into workflow | [ ] |
| 21 | Manual workflow dispatch (Bonus) | Built into workflow | [ ] |

---

## 🎯 Quick-Start Order of Operations

```
Day 1:
  Phase 0 → Install tools
  Phase 1 → Create S3 bucket + update backend.tf
  Phase 2 → Fork repo + create IAM user
  Phase 3 → Add GitHub Secrets & Variables
  Phase 4 → Create GitHub Environments with approval gates
  Phase 5 → Enable branch protection on main

Day 2:
  Phase 6 → First PR + pipeline run → approve apply → wait 20-30 min
  Phase 7 → Verify infrastructure with AWS CLI + kubectl

Day 3:
  Phase 8 → Install Kubernetes add-ons (ArgoCD, ESO, NGINX Ingress)
  Phase 9 → Deploy QA environment
  Phase 10 → Deploy Prod environment (if needed)
```

---

## Troubleshooting

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| `terraform init` fails with "bucket not found" | S3 bucket name wrong | Check `backend.tf` and `backend.tfvars` |
| Plan shows "Error: No valid credential sources found" | AWS creds not in GitHub Secrets | Verify `AWS_ACCESS_KEY_ID` secret exists |
| EKS nodes stuck in `NotReady` | Node IAM role missing policies | Terraform should have attached them; re-apply |
| `kubectl get nodes` returns empty | kubeconfig not updated | Run `aws eks update-kubeconfig ...` |
| `terraform apply` hangs at EKS | Normal! EKS takes 10-15 min | Just wait |
| RDS connection refused from pod | Security group not allowing EKS SG | Check `eks_security_group_id` variable passed to RDS module |
| GitHub Actions fails with "Not authorized" | IAM user doesn't have enough permissions | Attach `AdministratorAccess` temporarily |
| State lock not releasing | Previous run failed mid-apply | Delete `.terraform.tfstate.tflock` from S3 |

---

*Generated by Antigravity Agent — Last updated: 2026-08-17*
