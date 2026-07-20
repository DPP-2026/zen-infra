# Zen Pharma — CI/CD Architecture & Implementation

> **Stack**: GitHub Actions (CI + Promotion) · AWS ECR · ArgoCD (CD) · AWS EKS
> **Pattern**: GitOps · Build Once Deploy Many · PR-based Promotion Gates · Supply-Chain Security
> **Services**: 8 microservices (7 Java/Spring Boot + 1 React frontend)

---

## 1. Repository Structure

| Repository | Purpose | Branch strategy |
|---|---|---|
| `zen-pharma-frontend` | React UI (pharma-ui) | trunk-based (main + develop) |
| `zen-pharma-backend` | 7 backend microservices (monorepo) | trunk-based (main + develop) |
| `zen-gitops` | ArgoCD apps, Helm values, environment configs | main only |
| `zen-infra` | Terraform — VPC, EKS, RDS, ECR, IAM | main + PR workflow |

**Why this split:**
- Frontend and backend teams release independently
- `zen-gitops` is the single source of truth for *what is deployed* — never contains source code
- Infra changes go through a separate plan → approval → apply cycle

---

## 2. Technology Decisions

| Concern | Tool | Why |
|---|---|---|
| CI/CD | GitHub Actions | Native to GitHub, OIDC support, no extra infra |
| Container registry | AWS ECR | Provisioned by Terraform, scan-on-push enabled |
| SAST (Java) | CodeQL + Semgrep | CodeQL: deep call-graph analysis; Semgrep: OWASP rules |
| Dependency scan | OWASP Dependency-Check (Maven) | CVE database via NIST NVD, per-service HTML reports |
| Image scan | Trivy (Aqua) | Scans OS packages + app deps in the final image, SARIF to GitHub Security tab |
| Image signing | Cosign (keyless) | GitHub OIDC → Fulcio CA → Rekor log. No long-lived signing keys |
| Code quality | SonarCloud | SAST + code smells + coverage gate |
| Secret scan | Gitleaks | Catches secrets committed to the repo before they leave the runner |
| GitOps | ArgoCD | Pull-based CD, self-healing reconciliation, promotion via PRs |
| Secret management | AWS Secrets Manager + External Secrets Operator | Secrets never live in Git |
| AWS auth (CI) | OIDC (keyless) | No static `AWS_ACCESS_KEY_ID` stored in GitHub |
| AWS auth (pods) | IRSA | EKS pods assume IAM roles without credentials |

---

## 3. Design Philosophy

**1. Build Once, Deploy Many**
A Docker image is built and pushed to ECR exactly once, tagged with the git commit SHA. That same image flows through DEV → QA → PROD. No rebuilding per environment. This guarantees that what QA tested is exactly what runs in PROD.

**2. GitOps — Deployment is a git commit**
Kubernetes state is declared in `zen-gitops`, not controlled by imperative `kubectl apply` commands in CI. ArgoCD watches that repo and reconciles the cluster toward the declared state. Every deployment has a git history, an author, a timestamp, and is rollback-able by reverting a commit.

**3. Separation of concerns**
Application code lives in the backend/frontend repos. Deployment configuration lives in zen-gitops. CI only writes to zen-gitops — it never talks to Kubernetes directly.

**4. Shift security left**
Security checks run on feature branches before code is reviewed. A developer gets SAST and dependency CVE results in ~5 minutes on their own branch — at the point where it's cheapest to fix.

**5. Human gates at the right places**
DEV: fully automatic. QA: PR review in zen-gitops — QA team decides when to deploy. PROD: manual workflow_dispatch + Required Reviewers — intentional, audited, at a maintenance window.

---

## 4. End-to-End Flow

```
 Developer                GitHub Actions               zen-gitops (GitOps repo)         EKS
 ─────────                ──────────────               ────────────────────────         ───
    │                           │                               │                         │
    │  git push feat-*          │                               │                         │
    ├──────────────────────────►│                               │                         │
    │                           │ ci-pr-<service>.yml           │                         │
    │                           │ ┌─────────────────────────┐   │                         │
    │                           │ │ Gitleaks · Lint · Test  │   │                         │
    │                           │ │ CodeQL · Semgrep · OWASP│   │                         │
    │                           │ │ (no Docker, no ECR)     │   │                         │
    │                           │ └─────────────────────────┘   │                         │
    │  ✓ Fast feedback (~5 min) │                               │                         │
    │◄──────────────────────────│                               │                         │
    │                           │                               │                         │
    │  PR merged → develop      │                               │                         │
    ├──────────────────────────►│                               │                         │
    │                           │ ci-<service>.yml              │                         │
    │                           │ ┌─────────────────────────┐   │                         │
    │                           │ │ Full build pipeline     │   │                         │
    │                           │ │ Tests + SAST + OWASP    │   │                         │
    │                           │ │ Docker build + Trivy    │   │                         │
    │                           │ │ ECR push → sha-abc1234  │   │                         │
    │                           │ │ Cosign keyless sign     │   │                         │
    │                           │ └──────────┬──────────────┘   │                         │
    │                           │            │ image-tag output  │                         │
    │                           │ ┌──────────▼──────────────┐   │                         │
    │                           │ │ Job: deploy-dev         │   │                         │
    │                           │ │  git commit:            │   │                         │
    │                           │ │  envs/dev/values-*.yaml │──►│ ArgoCD polls            │
    │                           │ │  image.tag: sha-abc1234 │   │ every 3 min             │
    │                           │ └──────────┬──────────────┘   │──────────────────────►  │
    │                           │            │                   │  DEV auto-sync          │
    │                           │ ┌──────────▼──────────────┐   │                         │
    │                           │ │ Job: open-qa-pr         │   │                         │
    │                           │ │  yq patch qa values     │──►│ PR opened in zen-gitops │
    │                           │ │  gh pr create           │   │                         │
    │                           │ └─────────────────────────┘   │                         │
    │                           │                               │                         │
    │  QA team reviews PR       │                               │                         │
    ├──────────────────────────────────────────────────────────►│                         │
    │                           │                               │  PR merged              │
    │                           │                               │  ArgoCD auto-syncs ────►│
    │                           │                               │  QA namespace           │
    │                           │                               │                         │
    │  Release Manager triggers promote-prod.yml                │                         │
    ├──────────────────────────►│                               │                         │
    │                           │ ┌─────────────────────────┐   │                         │
    │                           │ │ Read image tag from QA  │   │                         │
    │                           │ │ yq patch prod values    │──►│ PR opened in zen-gitops │
    │                           │ └─────────────────────────┘   │                         │
    │                           │                               │  PR merged              │
    │                           │                               │  ArgoCD: OutOfSync      │
    │  Engineer syncs in ArgoCD UI at maintenance window        │──────────────────────►  │
    │                                                           │  PROD manual sync       │
```

---

## 5. Workflow File Map

```
zen-pharma-backend/
└── .github/
    └── workflows/
        │
        │  ── Reusable building blocks ─────────────────────────────────────────
        ├── _java-build.yml          ← Full build: Gitleaks + Maven + CodeQL + Semgrep +
        │                                          OWASP + Trivy + ECR + Cosign
        ├── _node-build.yml          ← Full build: Gitleaks + npm + CodeQL + Semgrep +
        │                                          audit + Trivy + ECR + Cosign
        ├── _java-pr-check.yml       ← Lightweight: Gitleaks + Maven + CodeQL + Semgrep +
        │                                           OWASP  (no Docker, no ECR)
        ├── _node-pr-check.yml       ← Lightweight: Gitleaks + npm + CodeQL + Semgrep +
        │                                           audit  (no Docker, no ECR)
        │
        │  ── Feature branch checks (feat-*, fix-*, chore-*) ──────────────────
        ├── ci-pr-api-gateway.yml
        ├── ci-pr-auth-service.yml
        ├── ci-pr-drug-catalog.yml
        ├── ci-pr-inventory-service.yml
        ├── ci-pr-manufacturing-service.yml
        ├── ci-pr-supplier-service.yml
        ├── ci-pr-notification.yml
        │
        │  ── Full build + DEV deploy + QA PR (develop / release/**) ──────────
        ├── ci-api-gateway.yml
        ├── ci-auth-service.yml
        ├── ci-drug-catalog.yml
        ├── ci-inventory-service.yml
        ├── ci-manufacturing-service.yml
        ├── ci-supplier-service.yml
        ├── ci-notification.yml
        │
        │  ── PROD promotion (manual trigger) ───────────────────────────────────
        └── promote-prod.yml
```

> **Why reusable workflows?** The full build pipeline has 8 stages. With 7 services, copying those stages inline would mean 56 copies of the same logic. Reusable workflows guarantee consistency — every service goes through identical security gates with no accidental variation.

> **Why two lightweight variants?** PR checks give full security feedback in ~5 minutes with no container overhead. A developer may push 10–15 times a day to a feature branch — running the full 15-minute pipeline would burn runner minutes and push dozens of unmerged images to ECR.

---

## 6. Branch → Workflow Trigger Matrix

| Event | Branches | Workflow triggered | What runs |
|---|---|---|---|
| `push` | `feat-*`, `fix-*`, `chore-*` | `ci-pr-<service>.yml` | Lint · Test · CodeQL · Semgrep · OWASP |
| `pull_request` | target: `develop` | `ci-pr-<service>.yml` | Same as above |
| `push` | `develop`, `release/**` | `ci-<service>.yml` | Full build + ECR + DEV deploy + open QA PR |
| `workflow_dispatch` | any | `promote-prod.yml` | Read QA tag → open PROD PR |

> **Why path filters on every workflow?** This is a monorepo with 7 services. Without path filters, pushing a one-line change to `notification-service/` would trigger all 7 pipelines. Each workflow is scoped to its own service directory (`notification-service/**`).

> **Why `develop` and `release/**` as the full-build trigger — not `main`?** `main` is the stable branch — nothing pushes directly to it except a merge. `develop` is the integration branch. `release/**` branches are created at sprint end for hotfixes. `main` has no workflow trigger — PROD is promoted via `promote-prod.yml`.

---

## 7. Three-Tier Promotion Model

```
┌────────────────────────────────────────────────────────────────────────┐
│  TIER 1 — Feature Branch (ci-pr-*.yml)                                 │
│                                                                        │
│  Trigger: push to feat-* / fix-* / chore-*,  or PR → develop          │
│  Goal:    fast feedback to developer, no side-effects                  │
│                                                                        │
│  Maven verify (+ Postgres if needed)                                   │
│  → CodeQL  → Semgrep  → OWASP Dependency Check                        │
│                                                                        │
│  No Docker build.  No ECR push.  No GitOps update.  (~5 min)          │
└────────────────────────────────────────────────────────────────────────┘
                              │ PR merged to develop
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│  TIER 2 — develop / release push (ci-*.yml)                            │
│                                                                        │
│  Job 1 · build                                                         │
│    Maven verify / npm ci  (+ Postgres container if needed)             │
│    CodeQL · Semgrep · OWASP Dep Check                                  │
│    Docker build (non-root UID 1000)                                    │
│    Trivy — fail on HIGH / CRITICAL                                     │
│    ECR push  →  image tag: sha-<7chars>                                │
│    Cosign keyless sign  (OIDC → Fulcio → Rekor)                        │
│                                                                        │
│  Job 2 · deploy-dev  (GitHub environment: dev)                         │
│    git commit: envs/dev/values-<service>.yaml  ← image.tag updated    │
│    git push → zen-gitops main                                          │
│    ArgoCD (pharma-dev) auto-syncs within ~3 min                        │
│                                                                        │
│  Job 3 · open-qa-pr  (needs: build + deploy-dev)                       │
│    git checkout -b promote/qa/<service>/<image-tag>  in zen-gitops     │
│    yq patch: envs/qa/values-<service>.yaml                             │
│    gh pr create → your-github-username/zen-gitops                      │
│    QA team reviews + merges the PR                                     │
│    ArgoCD (pharma-qa) auto-syncs on merge                              │
└────────────────────────────────────────────────────────────────────────┘
                              │ promote-prod.yml (workflow_dispatch)
                              ▼
┌────────────────────────────────────────────────────────────────────────┐
│  TIER 3 — PROD promotion (promote-prod.yml)                            │
│                                                                        │
│  Trigger: manual  (Release Manager selects service in dropdown)        │
│  GitHub environment: prod  (Required Reviewers gate before run)        │
│                                                                        │
│  Read image tag from envs/qa/values-<service>.yaml  (yq)              │
│  Validate envs/prod/values-<service>.yaml exists                       │
│  git checkout -b promote/prod/<service>/<image-tag>  in zen-gitops     │
│  yq patch: envs/prod/values-<service>.yaml                             │
│  gh pr create → your-github-username/zen-gitops                        │
│  After approvals: merge PR                                             │
│  ArgoCD (pharma-prod) shows OutOfSync → engineer syncs manually        │
│    at maintenance window                                               │
└────────────────────────────────────────────────────────────────────────┘
```

> **Why is QA promotion a PR instead of a direct git commit?** A PR gives: (1) a review gate, (2) a discussion thread per promotion, (3) ability to close if the build shouldn't go to QA yet, (4) permanent audit trail.

> **Why is PROD a separate `workflow_dispatch`?** If PROD were inline in `ci-*.yml`, the GitHub `prod` environment gate would block every DEV deployment waiting for PROD approval. A separate file means DEV deploys automatically while PROD is a standalone decision.

> **Why does PROD read the image tag from QA values instead of accepting input?** Reading from `envs/qa/values-<service>.yaml` ensures exactly what's running in QA gets promoted to PROD — no human error in tag selection.

---

## 8. CI Pipeline — Stage Detail

```
Push to develop / release/**
              │
              ▼
┌─────────────────────────────┐
│  1. Gitleaks — secret scan  │  Scans the HEAD commit for credentials/tokens
└─────────────┬───────────────┘
              ▼
┌──────────────────────────────────────────────────┐
│  2. Maven verify (tests + JaCoCo ≥ 80%)          │
│     └── PostgreSQL 15 sidecar (services w/ DB)   │  Real DB, no H2 surprises
└─────────────┬────────────────────────────────────┘
              ▼
┌─────────────────────────────────────────────────────────────┐
│  3. CodeQL — Java SAST                                       │
│     Instruments the Maven build (init before, analyze after) │
│     Queries: security-extended                               │
│     Results: GitHub Security tab (SARIF)                     │
└─────────────┬───────────────────────────────────────────────┘
              ▼
┌────────────────────────────────────────────────────┐
│  4. Semgrep SAST                                    │
│     Rules: p/java  p/spring-boot  p/owasp-top-ten  │
│     Continue-on-error: true (advisory, non-blocking)│
└─────────────┬──────────────────────────────────────┘
              ▼
┌────────────────────────────────────────────────────────┐
│  5. OWASP Dependency Check (CVSS ≥ 7.0)                │
│     Non-blocking — uploads HTML report as artifact     │
│     NVD DB cached across runs (actions/cache)          │
└─────────────┬──────────────────────────────────────────┘
              ▼
┌─────────────────────────────────────────────────────────────┐
│  6. Docker build                                             │
│     Base: eclipse-temurin:17-jre (runtime-only, no Maven)   │
│     Non-root user (UID/GID 1000)                            │
└─────────────┬───────────────────────────────────────────────┘
              ▼
┌───────────────────────────────────────────────────────────┐
│  7. Trivy — image vulnerability scan                       │
│     Severity: HIGH, CRITICAL  ·  ignore-unfixed: true      │
│     Output: SARIF → GitHub Security tab                    │
└─────────────┬─────────────────────────────────────────────┘
              ▼
┌─────────────────────────────────────────────────────────────┐
│  8. ECR push                                                 │
│     Tag: sha-<7chars>  (immutable, git-traceable)           │
│     Auth: OIDC → arn:aws:iam::<ACCOUNT>:role/pharma-github-actions-role │
└─────────────┬───────────────────────────────────────────────┘
              ▼
┌──────────────────────────────────────────────────────────────────┐
│  9. Cosign keyless sign                                           │
│     GitHub OIDC token → Fulcio CA (short-lived cert) → Rekor log │
│     Signature tied to repo + workflow identity, not a static key  │
└─────────────┬────────────────────────────────────────────────────┘
              ▼
┌──────────────────────────────────────────────────────────────┐
│  10. Update image tag in zen-gitops                          │
│     File: envs/dev/values-<service>.yaml                    │
│     Commit: "ci(dev): update <service> → sha-<7chars>"      │
└─────────────┬────────────────────────────────────────────────┘
              ▼
┌───────────────────────────────────────────────────────────────┐
│  11. Open QA promotion PR                                      │
│     Branch: promote/qa/<service>/<tag> in zen-gitops          │
│     PR body: checklist (dev smoke test, config review, QA sign-off) │
└───────────────────────────────────────────────────────────────┘
```

### Summary — What Runs Where

```
                          Feature branch    develop / release
Stage                     ci-pr-*.yml       ci-*.yml
─────                     ───────────       ────────
Unit tests                     ✓                ✓
Code coverage (JaCoCo/Jest)    ✓                ✓
Gitleaks (secrets)             ✓                ✓
CodeQL SAST                    ✓                ✓
Semgrep SAST                   ✓                ✓
OWASP Dependency Check (Java)  ✓                ✓
npm audit (Node)               ✓                ✓
Docker build                   ✗                ✓
Trivy image scan               ✗                ✓
ECR push                       ✗                ✓
Cosign sign                    ✗                ✓
GitOps DEV update              ✗                ✓
QA promotion PR                ✗                ✓

Approx. runtime                ~5 min           ~15 min
```

---

## 9. CD Pipeline — ArgoCD

```
zen-gitops commit (image tag updated by CI or promotion PR merge)
        │
        ▼
ArgoCD polls zen-gitops every 3 min (webhook → instant)
        │  detects drift between Git state and cluster state
        ▼
ArgoCD renders Helm chart with updated values file
        │  helm-charts/ + envs/<env>/values-<service>.yaml
        ▼
ArgoCD applies K8s manifests to target namespace
        │
        ▼
Kubernetes rolling update:
  - New pod starts → readinessProbe must pass
  - Old pod terminated (zero-downtime)
  - HPA adjusts replica count based on CPU
```

### Environment Promotion Flow

```
develop push
  → CI builds sha-<tag> → pushes to ECR → updates envs/dev/values-<svc>.yaml
  → ArgoCD auto-syncs dev namespace
  → CI opens PR: promote/qa/<svc>/<tag> in zen-gitops

QA sign-off (manual PR review + merge)
  → ArgoCD auto-syncs qa namespace

Production release (workflow_dispatch → promote-prod.yml)
  → Reads image tag from envs/qa/values-<svc>.yaml
  → Opens PR: promote/prod/<svc>/<tag> in zen-gitops
  → Requires 2 approvals
  → After merge: ArgoCD pharma-prod waits for manual sync
```

### ArgoCD App Structure

| Environment | App structure | Sync policy |
|---|---|---|
| `dev` | 8 individual Applications | Automated + selfHeal |
| `qa` | 1 `pharma-qa` app-of-apps | Automated + selfHeal |
| `prod` | 1 `pharma-prod` app-of-apps | **Manual sync** |

---

## 10. Service Matrix

| Service | Stack | Reusable workflow | DB in tests | ECR repo |
|---|---|---|---|---|
| api-gateway | Java 17 / Spring Cloud Gateway | `_java-build.yml` | No | `api-gateway` |
| auth-service | Java 17 / Spring Boot + JWT | `_java-build.yml` | Yes | `auth-service` |
| drug-catalog-service | Java 17 / Spring Boot + Flyway | `_java-build.yml` | Yes | `drug-catalog-service` |
| inventory-service | Java 17 / Spring Boot + Flyway | `_java-build.yml` | Yes | `inventory-service` |
| manufacturing-service | Java 17 / Spring Boot + Flyway | `_java-build.yml` | Yes | `manufacturing-service` |
| supplier-service | Java 17 / Spring Boot + Flyway | `_java-build.yml` | Yes | `supplier-service` |
| notification-service | Node.js 20 / Express + Jest | `_node-build.yml` | No | `notification-service` |
| pharma-ui | React 18 / Nginx | CI in `zen-pharma-frontend` | No | `pharma-ui` |

> **Why does `drug-catalog-service` use `catalog-service` in zen-gitops?** The GitOps repo was bootstrapped with `catalog-service` as the Helm release name. Renaming would require migrating ArgoCD apps and Helm release history. The `ci-drug-catalog.yml` workflow bridges this with `GITOPS_SERVICE_NAME: catalog-service`.

---

## 11. Security Architecture

### OIDC — No static AWS keys in CI

GitHub Actions exchanges its built-in OIDC token for a short-lived AWS credential via STS `AssumeRoleWithWebIdentity`. No `AWS_ACCESS_KEY_ID` is stored in GitHub Secrets.

```
GitHub Actions runner
  → POST to AWS STS with OIDC token
  → STS verifies token against OIDC provider (provisioned by Terraform)
  → Returns short-lived credentials (1 hour, scoped to the IAM role)
  → CI uses credentials for ECR login + ECR push
```

The IAM role trust policy is scoped to the specific GitHub org:
```json
{
  "Condition": {
    "StringLike": {
      "token.actions.githubusercontent.com:sub":
        "repo:your-github-username@283630436/zen-pharma-backend@1235515471:ref:refs/heads/*"
    }
  }
}
```

> Since 2026-07-15, GitHub enforces immutable `org@id/repo@id` subject claims for new/opted-in repos instead of bare names — this prevents a renamed or recycled repo/org from re-minting a matching token. The org/repo IDs are defined as `locals` in `modules/iam/github-actions-oidc.tf`.

### IRSA — Pods assume IAM roles without credentials

EKS pods that need AWS access (External Secrets Operator) are annotated with an IAM role ARN. EKS mutates the pod to mount a projected service account token, which pods exchange for AWS credentials via the cluster OIDC provider.

```
ESO pod
  → Reads projected token from /var/run/secrets/eks.amazonaws.com/serviceaccount/token
  → POST to AWS STS → returns short-lived credentials scoped to ESO IAM role
  → ESO calls secretsmanager:GetSecretValue to fetch /pharma/<env>/* secrets
  → Creates K8s Secret in the target namespace
```

### Cosign keyless signing

Every image pushed to ECR is signed without a long-lived key:
```
GitHub OIDC token (proves: this workflow, this repo, this commit)
  → Sigstore Fulcio CA issues a short-lived X.509 cert
  → Cosign creates a signature using the ephemeral cert
  → Signature + cert chain stored in Rekor transparency log
  → ECR image has an attached OCI signature artifact
```

Verification at deploy time can be enforced with a Kyverno policy in EKS.

---

## 12. Security Tooling — Industry Categories

| Category | Typical tools | Role | This project |
|---|---|---|---|
| SAST | CodeQL, Semgrep, Checkmarx | Find vulnerable patterns in source code | **CodeQL + Semgrep** |
| SCA | OWASP Dependency Check, Snyk, `npm audit` | Known CVEs in third-party libraries | **OWASP Dep Check + npm audit** |
| Secrets | Gitleaks, TruffleHog, GitHub secret scanning | Detect credentials committed to Git | **Gitleaks** |
| Container scan | Trivy, Grype, Clair, ECR native | Scan OS packages in container images | **Trivy** |
| Supply-chain signing | Cosign, Notation, Sigstore | Cryptographically sign images | **Cosign (keyless)** |
| DAST | OWASP ZAP, Burp Suite | Test running deployments | Not in build pipeline (separate schedule) |

---

## 13. Required Secrets

### zen-pharma-backend and zen-pharma-frontend

| Secret | Description |
|---|---|
| `AWS_ACCOUNT_ID` | 12-digit AWS account number |
| `GITOPS_TOKEN` | GitHub PAT with write access to zen-gitops |
| `SEMGREP_APP_TOKEN` | Semgrep Cloud token (optional — OSS rules work without it) |
| `NVD_API_KEY` | NIST NVD API key (optional — higher rate limits for OWASP) |

> No `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` needed — CI uses OIDC.

### zen-infra

| Secret | Description |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user with permissions to provision EKS, RDS, ECR, IAM |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret |
| `DEV_DB_PASSWORD` | RDS master password — passed to `terraform plan/apply` as `-var` |
| `DEV_JWT_SECRET` | JWT signing secret — stored in AWS Secrets Manager by Terraform |
| `GH_ORG` | Your GitHub username/org (repository variable, not secret) |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform state (repository variable) |

### Repository variables (zen-pharma-backend and zen-pharma-frontend)

| Variable | Value |
|---|---|
| `GITOPS_REPO` | `your-github-username/zen-gitops` |

---

## 14. Branch Protection Rules

### zen-pharma-backend / zen-pharma-frontend — `main` and `develop`

- Require PR before merging (no direct commits)
- Required status checks: `Build · SAST · Scan · Push · Sign`
- Require 1 reviewer approval
- Dismiss stale reviews on new commits

### zen-infra — `main`

- Require PR before merging
- Required status checks: `Terraform Plan`
- Require 2 reviewer approvals

### zen-gitops — `main`

- Require PR before merging
- No required CI checks (ArgoCD reads this repo directly)
- Require 1 reviewer for QA promotion PRs, 2 for PROD

---

## 15. Environment vs Branch Mapping

| Branch | CI triggered? | Deploys to | ArgoCD app |
|---|---|---|---|
| `feature/*` | PR checks only (no ECR push) | — | — |
| `develop` | Full pipeline + ECR push | dev namespace | `*-dev` (individual apps) |
| `release/**` | Full pipeline + ECR push | dev namespace | `*-dev` |
| `main` | PR check only | — | — |
| Gitops PR merge (QA) | N/A | qa namespace | `pharma-qa` (auto-sync) |
| Gitops PR merge (prod) | N/A | prod namespace | `pharma-prod` (manual sync) |

---

## 16. Reusable Workflows — Inputs

### `_java-build.yml` and `_java-pr-check.yml`

| Input | Type | Required | Default | Description |
|---|---|---|---|---|
| `service-name` | string | yes | — | Used in artifact names |
| `service-dir` | string | yes | — | Directory relative to repo root |
| `ecr-repository` | string | yes | — | ECR repo name (`_java-build.yml` only) |
| `aws-region` | string | no | `us-east-1` | AWS region |
| `needs-database` | boolean | no | `false` | Starts a Postgres 15 sidecar for tests |

**Outputs (`_java-build.yml` only):** `image-tag` (`sha-<7chars>`), `registry` (ECR URL)

### `_node-build.yml` and `_node-pr-check.yml`

Same inputs as Java equivalents with `node-version` (default `20`) replacing `needs-database`.

---

## 17. GitHub Environments — Required Setup

**Settings → Environments** in the `zen-pharma-backend` repo:

| Environment | Protection rule | Reviewers |
|---|---|---|
| `dev` | None (auto-deploys) | — |
| `prod` | Required reviewers | Release Manager + QA Lead |

> **Why does QA have no GitHub environment gate?** QA promotion is gated by the PR review in zen-gitops. Adding a GitHub environment would be a second gate on the same decision. The zen-gitops PR is actually stronger — it shows the exact diff, allows inline comments, and requires a separate account to approve.

---

## 18. Future Work

| Item | Recommendation |
|---|---|
| Integration / E2E tests | Playwright (UI) or RestAssured (API) as a separate CI job after image push |
| Performance tests | k6 or Gatling on a scheduled pipeline against dev |
| ArgoCD webhook | Add GitHub → ArgoCD webhook for instant sync (vs 3-min poll) |
| ArgoCD notifications | ArgoCD Notifications controller → Slack/email on sync failure |
| Kyverno admission policy | Verify Cosign image signature at pod admission |
| Multi-arch builds | `docker buildx` for `linux/amd64,linux/arm64` (Graviton node groups) |
| Dependabot | Automated dependency update PRs (complements OWASP/Trivy) |
| SBOM generation | Add Syft/Trivy SBOM output on every build for compliance |

---

## 19. FAQ

**Q: Why is there no ArgoCD CLI or smoke test in the pipeline?**
ArgoCD polls zen-gitops every ~3 minutes and syncs automatically. Smoke tests require network access into the private VPC which is not configured. Post-deploy health validation can be added as an ArgoCD `PostSync` hook.

**Q: Does PROD ever auto-sync?**
No. `pharma-prod` has `syncPolicy: Manual`. After the PROD PR merges, ArgoCD shows `OutOfSync`. An engineer syncs in the ArgoCD UI at the maintenance window.

**Q: How do I onboard a new microservice?**
1. Copy `ci-api-gateway.yml` (no DB) or `ci-auth-service.yml` (with DB) and rename throughout
2. Copy `ci-pr-api-gateway.yml` for the feature branch check
3. Add the service to the `options` list in `promote-prod.yml`
4. Create `envs/dev/values-<service>.yaml` in zen-gitops
5. Create an ArgoCD Application manifest in `zen-gitops/argocd/apps/dev/`
6. Add `envs/qa/` and `envs/prod/` values files when the service is ready

**Q: What happens if I push to `develop` but the QA values file doesn't exist yet?**
The `open-qa-pr` job exits with `::warning::` and exit code 0 — the pipeline succeeds. DEV still gets the new image. Create `envs/qa/values-<service>.yaml` in zen-gitops to enable QA promotion.

**Q: What is the image tag format?**
`sha-<first 7 chars of git SHA>` — e.g. `sha-abc1234`. Set in the reusable build workflows via:
```bash
echo "image_tag=sha-${GITHUB_SHA::7}" >> $GITHUB_OUTPUT
```
