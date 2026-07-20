# Zen Pharma — DevOps Interview Questions

> All questions are scenario-based and tied directly to the zen-pharma project.
> Every answer can be backed by real code you wrote.

---

## Section 1 — Terraform Fundamentals

**Q1.** You need to add a 9th microservice called `reporting-service` to the platform. Walk me through every file you would change and what would happen when you run the pipeline.

<details>
<summary>Expected answer</summary>

Add `"reporting-service"` to the `repositories` list in `envs/dev/main.tf` (inside the `module "ecr"` call). That is the only change required.

When the pipeline runs:
- `terraform plan` shows **2 new resources**: `aws_ecr_repository.main["reporting-service"]` and `aws_ecr_lifecycle_policy.main["reporting-service"]`
- The `for_each = toset(var.repositories)` loop in `modules/ecr/main.tf` stamps out one repo + one lifecycle policy for every item in the list
- `terraform apply` creates both resources. `scan_on_push = true` and the keep-last-10 policy are applied automatically — no extra code needed

No other module is affected because `module.ecr` has no outputs that feed into other modules.

</details>

---

**Q2.** A junior engineer ran `terraform apply` directly from their laptop and accidentally changed the EKS node group instance type from `t3.small` to `t3.large`. The pipeline runs the next day and shows a plan with 0 changes. Why? How do you detect and fix this?

<details>
<summary>Expected answer</summary>

The pipeline showed 0 changes because the `t3.large` is now the **real state in AWS**, and it matches the state file in S3. Terraform compares code → state file → real AWS. If the state file was updated by the local apply, Terraform thinks everything is already correct.

To detect drift:
```bash
cd envs/dev
terraform plan \
  -var="db_password=dummy" \
  -var="jwt_secret=dummy" \
  -var="github_org=your-username"
# If the plan shows changes that nobody approved, that is drift
```

To fix: revert `node_instance_type` in `envs/dev/main.tf` back to `t3.small`, open a PR, let the pipeline plan show the change, then merge and approve.

Prevention: the pipeline uses a GitHub Environment with required reviewers. Nobody should have `terraform apply` access from a laptop in a real team — the IAM user used locally should be read-only.

</details>

---

**Q3.** Your `terraform apply` fails halfway through. EKS was created but RDS failed. What happens to the state file? What do you do next?

<details>
<summary>Expected answer</summary>

Terraform updates the S3 state file **for every resource it successfully creates**. So after a partial apply, the state file reflects what was created before the failure — the EKS cluster is in state, the RDS instance is not.

Steps:
1. Read the error in the GitHub Actions logs (expand the Apply step, scroll up from the bottom)
2. Fix the root cause — e.g. if RDS failed because the subnet group didn't exist, check the `subnet_ids` variable
3. Re-trigger the pipeline — **do not cancel or manually delete** the partial state
4. Terraform will pick up from where it left off: EKS already exists (matches state), so only the missing RDS resources will be created

If the state file gets locked (error: `Error acquiring the state lock`), a previous apply crashed mid-run. Fix:
```bash
terraform force-unlock <LOCK-ID>
# Lock ID is printed in the error message
```

</details>

---

**Q4.** Explain what happens when you change a module output. For example, you rename `private_eks_subnet_ids` to `eks_subnet_ids` in `modules/vpc/outputs.tf`. Where will `terraform plan` fail and why?

<details>
<summary>Expected answer</summary>

It will fail at **plan time** with a reference error, not an apply error. The EKS module call in `envs/dev/main.tf` references `module.vpc.private_eks_subnet_ids`. When you rename the output, Terraform can no longer resolve that reference during the plan phase — it throws:

```
Error: Unsupported attribute
  module.vpc does not have an attribute named "private_eks_subnet_ids"
```

You must update every consumer of that output at the same time — in this case `envs/dev/main.tf`, `envs/qa/main.tf`, and `envs/prod/main.tf`. This is why renaming module outputs is a breaking change and should be done in its own PR with a careful review.

</details>

---

## Section 2 — VPC and Networking

**Q5.** A developer says "I can't connect to the RDS database from my laptop even though I'm on the company VPN." Is this expected? How would you give them access temporarily for debugging?

<details>
<summary>Expected answer</summary>

Yes, this is **expected and correct behaviour**. The RDS security group only allows inbound on port 5432 from `eks_security_group_id`. A VPN puts the developer on the company network, not inside the EKS security group — so the rule never matches.

Options for temporary access:

**Option 1 — Port-forward via kubectl (recommended, no infra change):**
```bash
kubectl run pg-debug --image=postgres:15 --restart=Never -- sleep 3600
kubectl exec -it pg-debug -- psql \
  -h <rds_endpoint> -U pharmaadmin -d pharmadb
```
This works because the pod is running inside EKS and its network interface is in the EKS security group.

**Option 2 — Add a temporary SG rule (risky, needs cleanup):**
Add an ingress rule for the developer's VPN IP to the RDS security group. Remove it immediately after. In Terraform this is a change you commit, open PR, merge, and then immediately revert — to leave an audit trail.

**Never** set `publicly_accessible = true` on the RDS instance to solve this.

</details>

---

**Q6.** The EKS worker nodes in `us-east-1a` have stopped being able to pull Docker images from ECR. Nodes in `us-east-1b` are fine. What is the most likely cause?

<details>
<summary>Expected answer</summary>

The most likely cause is that the **NAT Gateway is down or has lost its Elastic IP**. In the current `modules/vpc` setup there is a **single NAT Gateway** in `public[0]` (us-east-1a). Both private EKS subnets in 1a and 1b route through this single NAT via the shared private route table.

Wait — if 1b nodes are fine but 1a nodes are not, it would suggest a subnet-level issue rather than the NAT (since both use the same NAT). In that case check:
- The route table association for `private_eks` subnet in 1a — it may have been accidentally disassociated
- The subnet's NACL (network ACL) — if someone added a deny rule
- The EKS security group — if a rule was modified

The deeper interview point: **for production HA** you would create one NAT Gateway per AZ, each with its own private route table pointing to the local NAT. Then losing the NAT in 1a would not affect 1b at all. The current `modules/vpc` code uses a single shared NAT to save ~$32/month, which is correct for dev but not for prod.

</details>

---

**Q7.** What are the Kubernetes tags on the private EKS subnets and why are they critical?

<details>
<summary>Expected answer</summary>

Two tags are set on `aws_subnet.private_eks`:

```hcl
"kubernetes.io/role/internal-elb" = "1"
"kubernetes.io/cluster/${var.project}-${var.env}-cluster" = "owned"
```

Without `kubernetes.io/role/internal-elb = 1`, the **AWS Load Balancer Controller** cannot discover which subnets to place internal load balancers in. Any Kubernetes `Service` of type `LoadBalancer` or `Ingress` will stay in `Pending` state indefinitely — it looks like a networking bug but it is actually a missing tag.

Without `kubernetes.io/cluster/…cluster = owned`, EKS cannot tag and manage the subnet for node placement. The cluster may fail to add new nodes or the VPC CNI plugin may have trouble allocating pod IPs.

These tags cost nothing and forgetting them is a very common real-world mistake.

</details>

---

## Section 3 — EKS and Kubernetes

**Q8.** You just ran `terraform apply` and the EKS cluster was created, but `kubectl get nodes` shows 0 nodes after 10 minutes. What do you check?

<details>
<summary>Expected answer</summary>

Check in this order:

1. **Node group IAM role** — the three policy attachments in `modules/eks/main.tf` must exist before the node group. If `terraform apply` failed between creating the role and attaching the policies, nodes will spin up but cannot join the cluster (no `AmazonEKSWorkerNodePolicy`).

2. **`depends_on` in `aws_eks_node_group`** — the code has:
   ```hcl
   depends_on = [
     aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
     aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
     aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
   ]
   ```
   If a partial apply happened, this dependency chain may not have completed.

3. **Subnet IDs** — check that `var.subnet_ids` received the private EKS subnet IDs (not the RDS subnets, not the public subnets).

4. **`aws-auth` ConfigMap** — the cluster was created with `bootstrap_cluster_creator_admin_permissions = true`. If a different IAM identity created the cluster vs. what you are using for `kubectl`, you may need to add your IAM role to `aws-auth`.

```bash
aws eks update-kubeconfig --region us-east-1 --name zen-pharma-dev-cluster
kubectl get nodes
kubectl describe node <node-name>  # check events
```

</details>

---

**Q9.** Explain IRSA in plain English. Why is it better than putting `AWS_ACCESS_KEY_ID` in a Kubernetes Secret?

<details>
<summary>Expected answer</summary>

**IRSA (IAM Roles for Service Accounts)** lets a Kubernetes pod get temporary AWS credentials automatically, without storing any long-lived keys anywhere.

Here is how it works step by step in the zen-pharma project:

1. When Terraform runs `modules/eks`, it creates an **OIDC provider** (`aws_iam_openid_connect_provider`) registered with AWS IAM. This tells AWS: *"trust JWT tokens signed by this EKS cluster."*

2. When Terraform runs `modules/iam`, it creates the ESO IRSA role with a **trust policy condition**:
   ```
   system:serviceaccount:external-secrets:external-secrets
   ```
   This means: *"only the service account named `external-secrets` in the `external-secrets` namespace can assume this role."*

3. At runtime, Kubernetes **projects a signed JWT token** into the ESO pod's filesystem automatically.

4. The ESO pod calls AWS STS with that token. STS validates it against the OIDC provider and returns **1-hour temporary credentials**.

5. ESO uses those credentials to call `secretsmanager:GetSecretValue` on `/pharma/*`.

**Why it is better than a static key:**
- A static `AWS_ACCESS_KEY_ID` stored in a K8s Secret can be read by anyone with `kubectl get secret` in that namespace — or anyone with S3/etcd access
- Static keys never expire — a leaked key is valid until manually rotated
- IRSA credentials expire in 1 hour and are scoped to exactly the permissions in the IAM role
- There is nothing to rotate, nothing to leak, nothing to store

</details>

---

**Q10.** The `argocd-application-controller` pod is crashing with an `Unauthorized` error when trying to sync resources. What would you check?

<details>
<summary>Expected answer</summary>

The ArgoCD IRSA role (`modules/iam/main.tf`) has a trust policy condition:

```hcl
"system:serviceaccount:argocd:argocd-application-controller"
```

Check in this order:

1. **Namespace name** — is ArgoCD actually installed in the `argocd` namespace? If it was installed in `argocd-system` or another namespace, the trust condition never matches and STS rejects the token.

2. **Service account annotation** — the Helm values for ArgoCD must annotate the service account with the role ARN:
   ```yaml
   serviceAccount:
     annotations:
       eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/zen-pharma-dev-argocd-role
   ```
   If this annotation is missing, Kubernetes does not project the OIDC token into the pod.

3. **OIDC provider ARN** — verify `var.oidc_provider_arn` in `modules/iam` received the correct value from `module.eks.oidc_provider_arn`. A mismatch means the trust policy references a different cluster's OIDC provider.

4. **ArgoCD role has no AWS permissions attached** — this is correct. The role exists purely for EKS authentication. ArgoCD's access to Kubernetes resources is controlled by K8s RBAC (the `aws-auth` ConfigMap), not IAM policies.

</details>

---

## Section 4 — CI/CD and GitHub Actions

**Q11.** A developer pushed a feature branch and the GitHub Actions pipeline ran. The Terraform Plan showed the correct changes. But after they merged to `main`, the apply job was skipped entirely. Why?

<details>
<summary>Expected answer</summary>

The `terraform.yml` workflow uses a **path filter**:

```yaml
on:
  push:
    branches: [main]
    paths:
      - 'envs/dev/**'
      - 'modules/**'
```

The apply job only triggers when files under `envs/dev/` or `modules/` are changed. If the developer only changed files in `.github/workflows/` or a documentation file, the paths filter does not match — GitHub skips the workflow entirely even after a merge to `main`.

To verify: go to Actions tab → the workflow should show as skipped with a note about the path filter. Ask the developer what files they changed.

</details>

---

**Q12.** You are asked to allow a new GitHub repository `zen-pharma-reporting` to push Docker images to ECR. What Terraform change do you make?

<details>
<summary>Expected answer</summary>

In `modules/iam/github-actions-oidc.tf`, the trust policy condition uses `StringLike` on the `sub` claim. Since 2026-07-15 GitHub enforces immutable `org@id/repo@id` subject claims (instead of bare names) for new/opted-in repos, so the claim values interpolate a `local.github_repo_id_reporting`-style ID alongside the name:

```hcl
locals {
  github_org_id           = "283630436"  # DPP-2026
  github_repo_id_frontend = "1235505603" # DPP-2026/zen-pharma-frontend
  github_repo_id_backend  = "1235515471" # DPP-2026/zen-pharma-backend
  # Add this line with the new repo's numeric GitHub ID:
  github_repo_id_reporting = "<repo-id>" # DPP-2026/zen-pharma-reporting
}

condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values = [
    "repo:${var.github_org}@${local.github_org_id}/zen-pharma-frontend@${local.github_repo_id_frontend}:ref:refs/heads/main",
    "repo:${var.github_org}@${local.github_org_id}/zen-pharma-frontend@${local.github_repo_id_frontend}:ref:refs/heads/develop",
    "repo:${var.github_org}@${local.github_org_id}/zen-pharma-backend@${local.github_repo_id_backend}:ref:refs/heads/main",
    "repo:${var.github_org}@${local.github_org_id}/zen-pharma-backend@${local.github_repo_id_backend}:ref:refs/heads/develop",
    # Add these two lines:
    "repo:${var.github_org}@${local.github_org_id}/zen-pharma-reporting@${local.github_repo_id_reporting}:ref:refs/heads/main",
    "repo:${var.github_org}@${local.github_org_id}/zen-pharma-reporting@${local.github_repo_id_reporting}:ref:refs/heads/develop",
  ]
}
```

The repo's numeric ID can be found via `gh api repos/DPP-2026/zen-pharma-reporting --jq .id`. Open a PR with this change. `terraform plan` will show an update to `aws_iam_role.github_actions_ci` (the trust policy changes). No new resources are created — the existing role now trusts the additional repo. After apply, add the role ARN to the new repo's GitHub Variables and use `aws-actions/configure-aws-credentials` in its workflow.

Note: the permission policy (`ECRPush`) already allows `arn:aws:ecr:*:ACCOUNT:repository/*` — all repos in the account. The trust policy is the real security gate.

</details>

---

**Q13.** Explain the difference between `terraform fmt -check`, `terraform validate`, and `terraform plan`. Why does the pipeline run all three in that order?

<details>
<summary>Expected answer</summary>

They catch different categories of errors, from cheap to expensive:

| Command | What it checks | Cost |
|---|---|---|
| `terraform fmt -check` | Code formatting only — indentation, spacing | Milliseconds, no AWS call |
| `terraform validate` | HCL syntax and type correctness — no AWS calls | Seconds, no AWS call |
| `terraform plan` | What will actually change in AWS — calls AWS APIs | 30–60 seconds, AWS API calls |

Running them in this order means:
- A formatting error (e.g. forgotten indent) fails in milliseconds instead of waiting 60 seconds for a plan
- A type error (e.g. passing a `string` where `list(string)` is expected) fails before any AWS calls
- Only well-formatted, syntactically valid code proceeds to the expensive plan step

In the `zen-infra` pipeline, `terraform fmt -check` failing blocks the PR from merging. This enforces consistent formatting across the whole team — no arguments about tabs vs spaces.

</details>

---

## Section 5 — Security

**Q14.** A security audit flags that your RDS password is visible in the Terraform state file. How do you respond?

<details>
<summary>Expected answer</summary>

This is a known Terraform behaviour — sensitive values in `aws_db_instance` are stored in the state file. The `modules/rds/variables.tf` marks `db_password` as `sensitive = true`, which prevents it from appearing in logs and plan output, but **it does not encrypt the state file**.

Mitigations already in place in zen-pharma:

1. **S3 state backend with encryption** — the bucket was created with `AES256` server-side encryption and public access blocked. The state file at rest is encrypted.

2. **S3 versioning** — if the state file is compromised, earlier versions without the secret can be restored.

3. **The real mitigation is ESO** — the `db_password` in the state file is the RDS master password, but applications never use it directly. They connect using credentials from Secrets Manager, which ESO syncs into K8s. If the state file leaked, the attacker has the master RDS password — bad, but it can be rotated without touching application code.

**Improvement for production:** Use Terraform's [`sensitive` output suppression](https://developer.hashicorp.com/terraform/language/values/outputs#sensitive) and consider using AWS Secrets Manager to generate the password (`aws_secretsmanager_random_password`) so the password is never in Terraform variables at all — it is generated by AWS and Terraform reads it back via data source.

</details>

---

**Q15.** You need to give a new team member `read-only` access to see what Terraform would change, but not be able to apply. How do you set this up?

<details>
<summary>Expected answer</summary>

Two parts:

**AWS side** — Create a new IAM policy with only read permissions:
```json
{
  "Action": ["ec2:Describe*", "eks:Describe*", "rds:Describe*", "ecr:Describe*", "s3:GetObject", "s3:ListBucket"],
  "Effect": "Allow",
  "Resource": "*"
}
```
Attach it to the new team member's IAM user. They can run `terraform plan` (which only reads from AWS) but `terraform apply` will fail on any write action.

**GitHub side** — The GitHub Environment (`dev`) has Required Reviewers. The new member can view the Actions tab and see plan output on every PR. They cannot approve the apply job unless added as a reviewer.

**Practically** — the easiest approach is to give them repository read access on GitHub and the read-only IAM policy. They can clone the repo, run `terraform plan` locally, see the output, and comment on PRs — but they cannot merge to `main` or approve the apply gate.

</details>

---

**Q16.** The GitHub Actions OIDC role has `max_session_duration = 3600`. A CI job for building Docker images is taking 75 minutes because the image is very large. What happens and how do you fix it?

<details>
<summary>Expected answer</summary>

After 60 minutes the STS credentials expire. The `docker push` step will fail with an authentication error — ECR returns `no basic auth credentials` or a 401.

Fix options:

1. **Increase `max_session_duration`** in Terraform:
   ```hcl
   max_session_duration = 7200  # 2 hours
   ```
   AWS allows up to 12 hours for OIDC roles. Open a PR, merge, apply. The change takes effect immediately for new workflow runs.

2. **Optimise the Docker build** — multi-stage builds, `.dockerignore` to exclude unnecessary files, layer caching (`actions/cache` for Docker layers). A 75-minute build is a sign the image needs refactoring regardless of the auth issue.

3. **Re-authenticate mid-job** — call `aws-actions/configure-aws-credentials` a second time before the push step. This mints a fresh token and extends the window.

Option 1 is the immediate fix. Option 2 is the right long-term fix.

</details>

---

## Section 6 — Troubleshooting Scenarios

**Q17.** After a `terraform apply` succeeds, a developer runs `kubectl apply -f deployment.yaml` and the pod fails to start with `ImagePullBackOff`. Walk through your debugging steps.

<details>
<summary>Expected answer</summary>

`ImagePullBackOff` means the node cannot pull the Docker image from ECR.

Step-by-step:

```bash
kubectl describe pod <pod-name> -n <namespace>
# Look at Events section — it will say something like:
# Failed to pull image "123456789012.dkr.ecr.us-east-1.amazonaws.com/auth-service:latest"
# unauthorized: authentication required
```

Possible causes and checks:

1. **Wrong ECR URL** — confirm the image URI in the deployment matches the ECR repository URL from `module.ecr.repository_urls["auth-service"]`

2. **Node group IAM role missing ECR policy** — the `AmazonEC2ContainerRegistryReadOnly` policy must be attached to the node group role. Check in AWS Console → IAM → Roles → `zen-pharma-dev-eks-node-group-role` → Permissions tab

3. **Image does not exist in ECR** — the CI pipeline may not have pushed the image yet. Check ECR → repository → Images tab. If the tag `latest` does not exist, the CI job failed or was never run

4. **Region mismatch** — the image URI must use the same region as the cluster (`us-east-1`)

5. **`imagePullSecrets` missing** — for private ECR, nodes use their IAM role to authenticate. No `imagePullSecrets` are needed if the node role has the ECR policy. If someone added an incorrect `imagePullSecrets` it may be interfering

</details>

---

**Q18.** You are paged at 2 AM: the pharma application is returning 503 errors. `kubectl get pods` shows all pods `Running`. `kubectl get nodes` shows all nodes `Ready`. Where do you look next?

<details>
<summary>Expected answer</summary>

All pods and nodes are healthy, so the issue is likely at the networking or routing layer.

Check in this order:

```bash
# 1. Check the Ingress
kubectl get ingress -A
kubectl describe ingress <ingress-name>
# Look for: Address (should be the NLB DNS name), and any events

# 2. Check the NLB in AWS Console
# EC2 → Load Balancers → find the NLB created by NGINX Ingress
# Target Group → check target health — are the targets healthy?

# 3. Check NGINX Ingress Controller pods
kubectl get pods -n ingress-nginx
kubectl logs -n ingress-nginx <ingress-nginx-controller-pod>

# 4. Check the API Gateway service
kubectl get svc -A
kubectl describe svc api-gateway
# Is the ClusterIP resolving? Are the endpoint slices populated?

# 5. Check RDS connectivity from a pod
kubectl run debug --image=postgres:15 --restart=Never -- sleep 300
kubectl exec -it debug -- pg_isready -h <rds_endpoint> -p 5432
# If this fails, the RDS security group or subnet routing may have changed
```

The most common 2 AM cause after "everything looks fine": the NLB target group health checks are failing (even though pods are Running), or a recent deployment changed a service selector that no longer matches the pod labels.

</details>

---

**Q19.** Terraform state shows `aws_eks_node_group.main` exists, but `kubectl get nodes` returns 0 nodes. The node group in AWS Console shows "Active" with 3/3 desired nodes. What is happening?

<details>
<summary>Expected answer</summary>

The nodes exist in AWS but cannot join the cluster. This is almost always a `aws-auth` ConfigMap issue.

```bash
kubectl get configmap aws-auth -n kube-system -o yaml
```

The `aws-auth` ConfigMap must contain a `mapRoles` entry for the node group IAM role ARN:

```yaml
mapRoles:
- rolearn: arn:aws:iam::123456789012:role/zen-pharma-dev-eks-node-group-role
  username: system:node:{{EC2PrivateDNSName}}
  groups:
  - system:bootstrappers
  - system:nodes
```

In the zen-pharma project, `bootstrap_cluster_creator_admin_permissions = true` in the `access_config` block handles the cluster creator's access. However, the node group role still needs to be in `aws-auth` for nodes to register.

If the `aws-auth` ConfigMap entry is missing, nodes will reach the API server, present their credentials, and be denied. They will show as Active in the AWS Console (the EC2 instances are running) but `kubectl get nodes` shows nothing because they never completed registration.

Fix: add the `mapRoles` entry and within a minute the nodes should appear in `kubectl get nodes`.

</details>

---

**Q20.** A `terraform plan` on the `modules/rds` module shows that the RDS instance will be **destroyed and recreated** — even though you only changed `backup_retention_period` from 0 to 7. Why could this happen and is it safe to apply?

<details>
<summary>Expected answer</summary>

**Why recreation happens:** Some RDS attributes cannot be changed in-place — they require a replacement. `backup_retention_period` is actually a **modifiable attribute** that does NOT force recreation. If the plan shows recreation, look at what else changed:

- `db_name` — cannot be changed after creation; forces replacement
- `engine_version` with a major version jump — may force replacement
- `identifier` — changing the DB identifier forces replacement
- `storage_type` from `gp2` to `gp3` — can be changed in-place in recent Terraform AWS provider versions
- `allocated_storage` decrease — cannot be decreased, forces replacement

**How to read the plan carefully:**
```
# aws_db_instance.main must be replaced
-/+ resource "aws_db_instance" "main" {
    ...
  ~ db_name = "pharmadb" -> "PharmaDB"  # forces replacement
```

The `#` force symbol and `-/+` notation confirm recreation. The line causing it will have `# forces replacement` next to it.

**Is it safe to apply?** If the plan shows recreation:
- In dev: yes, apply it — accept data loss, the DB will be empty after recreation
- In prod: **never apply without a manual RDS snapshot first**. `deletion_protection = true` in prod will actually block the destroy step — the apply will fail with a protection error, giving you a safety net

</details>

---

## Quick-fire round — "How would you…"

| Scenario | Answer |
|---|---|
| Scale EKS from 3 to 5 nodes | Change `desired_capacity = 5` in `envs/dev/main.tf`, open PR, merge, approve apply |
| Check what changed in AWS outside Terraform | `terraform plan` — any diff between state and real AWS shows as a change to be corrected |
| Rotate the RDS master password | Update `DEV_DB_PASSWORD` in GitHub Secrets, re-run the pipeline — Terraform will update the `aws_db_instance` password and the Secrets Manager secret version |
| Destroy only the RDS instance, not the whole stack | `terraform destroy -target=module.rds` — targets a single module |
| Find the cost of the dev environment | EKS $72/month + 3×t3.small $43/month + RDS $14/month + NAT Gateway $32/month ≈ **$160–180/month** |
| Add a second environment `staging` | Copy `envs/dev/` to `envs/staging/`, update `backend.tf` key, create GitHub Environment `staging`, add secrets, run pipeline |
| Prevent a merge if terraform plan fails | The pipeline blocks the PR — the plan job must pass before the branch protection rule allows merge |

---

*Built from: zen-infra · zen-gitops · zen-pharma-frontend · zen-pharma-backend*
*Stack: Terraform 1.10 · GitHub Actions · AWS EKS 1.33 · RDS PostgreSQL 15.7 · ECR · IAM OIDC/IRSA · Secrets Manager · S3*
