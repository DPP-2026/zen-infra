# Karpenter Demo — dev environment

A runbook for demonstrating Karpenter node autoscaling on `pharma-dev-cluster` once
the `modules/karpenter` stack has been applied via the `Terraform Infrastructure`
GitHub Actions workflow.

Cluster: `pharma-dev-cluster` · Region: `us-east-1` · NodePool: `default`
(spot + on-demand, instance categories `c`/`m`/`r`, 40 vCPU cap, consolidates
after 1 minute of being empty/underutilized)

---

## 0. Prerequisites

1. Merge/apply `feature/karpenter-integration` to `main` (or run the workflow
   manually with `environment=dev`, `action=apply`) so the karpenter module
   provisions.
2. Point `kubectl` at the cluster:

   ```bash
   aws eks update-kubeconfig --name pharma-dev-cluster --region us-east-1
   kubectl config current-context
   ```

---

## 0.5 Known one-time gotchas (already fixed for pharma-dev, watch for these on a fresh account/cluster)

These bit us running this demo for the first time against `pharma-dev-cluster`. Neither is
a Terraform bug — both are one-time, account/cluster-level state that Terraform doesn't
(and largely can't) manage, so they're easy to hit again on a new environment or a
from-scratch AWS account.

### a) Stale CRDs after a Karpenter version bump

**Symptom:** `EC2NodeClass`/`NodePool` apply fine, but new `NodeClaim`s fail validation
with something like:

```
NodeClaim.karpenter.sh "default-xxxxx" is invalid: [spec.requirements[N].operator:
Unsupported value: "Gte": supported values: "In", "NotIn", "Exists", "DoesNotExist", "Gt", "Lt", ...]
```

**Cause:** the `karpenter` Helm chart installs CRDs via its `crds/` directory, and Helm's
`crds/` mechanism only *creates* CRDs if they're absent — it never upgrades an existing
one on `helm install`/`upgrade`, even across major version bumps. If CRDs were ever
installed by an older chart version (e.g. an earlier failed attempt), they silently stick
around and the controller (now running newer code) starts writing fields/enum values the
stale CRD schema doesn't allow.

**Fix:** reapply the CRDs for the target version directly:

```bash
KARPENTER_VERSION=1.11.3  # match modules/karpenter/variables.tf karpenter_version
for f in karpenter.sh_nodepools.yaml karpenter.sh_nodeclaims.yaml karpenter.k8s.aws_ec2nodeclasses.yaml; do
  kubectl apply -f "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/pkg/apis/crds/$f"
done
```

Do this any time `karpenter_version` is bumped in a cluster that's had a previous
Karpenter install attempt (successful or not).

### b) `AWSServiceRoleForEC2Spot` doesn't exist yet

**Symptom:** `NodeClaim`s targeting spot capacity fail to launch with:

```
AuthFailure.ServiceLinkedRoleCreationNotPermitted: The provided credentials do not have
permission to create the service-linked role for EC2 Spot Instances.
```

**Cause:** the very first EC2 Spot request in an AWS account needs the
`AWSServiceRoleForEC2Spot` service-linked role to exist. AWS normally auto-creates it on
first use, but the Karpenter controller's scoped IAM policy (deliberately) doesn't include
`iam:CreateServiceLinkedRole`, so if this account has never launched a spot instance
before, Karpenter can't create it for itself.

**Fix:** create it once, with any sufficiently-privileged identity (not the Karpenter
controller role) — it's an account-wide fixture, not per-cluster or per-environment:

```bash
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

Safe to run even if it might already exist elsewhere in the account — check first with
`aws iam get-role --role-name AWSServiceRoleForEC2Spot` if unsure. Not something to add to
`modules/karpenter` itself: it's a one-time account bootstrap step, and every environment's
module would otherwise try to create the same account-wide role and collide.

### c) Also worth knowing: this account's on-demand vCPU quota

`pharma-dev`'s EC2 "Running On-Demand Standard (A,C,D,H,I,M,R,T,Z) instances" quota is `8`
vCPUs — already fully consumed by the 4× `t3.small` managed node group (2 vCPU × 4 = 8).
That's why the scale-up demo below only succeeds via **spot** capacity; Karpenter will keep
retrying on-demand launches and failing with `VcpuLimitExceeded` until either this quota is
raised or the managed node group is scaled down to free headroom. Not a bug — just a sandbox
account limit worth knowing about before a live demo, since Karpenter's `NodePool` allows both
`spot` and `on-demand` and will only silently fall back to whichever one actually has room.

---

## 1. Verify Karpenter is healthy

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
kubectl get ec2nodeclass default
kubectl get nodepool default -o yaml
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f
```

You should see 2 controller pods `Running`, the `default` EC2NodeClass/NodePool
present, and the existing managed-node-group nodes (t3.small, desired=4) as the
only nodes so far — Karpenter hasn't launched anything yet because nothing has
asked for capacity it can't fit.

---

## 2. Scale-up demo — force Karpenter to provision a node

Deploy a workload whose pods deliberately don't fit on the existing t3.small
nodes (2 vCPU / 2 GiB each, already carrying the platform's own pods):

```bash
kubectl create deployment inflate --image=public.ecr.aws/eks-distro/kubernetes/pause:3.7
kubectl set resources deployment inflate --requests=cpu=1,memory=1Gi
kubectl scale deployment inflate --replicas=10
```

Watch pods go `Pending`, then watch Karpenter react:

```bash
kubectl get pods -l app=inflate -w          # Pending -> Running as nodes come up
kubectl get nodes -w                         # new node(s) appear, labeled karpenter.sh/*
kubectl get nodeclaims                       # Karpenter's record of what it launched
```

Inspect what Karpenter chose:

```bash
kubectl get nodeclaims -o custom-columns='NAME:.metadata.name,TYPE:.status.allocatable,ZONE:.metadata.labels.topology\.kubernetes\.io/zone,CAPACITY:.metadata.labels.karpenter\.sh/capacity-type'
```

Talking points:
- Karpenter picked the instance type/AZ itself (`c`/`m`/`r` families, spot-first)
  from live EC2 pricing/capacity — no pre-defined node group sizing.
- New nodes joined via an **EKS access entry** (`aws_eks_access_entry.karpenter_node`
  in `modules/karpenter/main.tf`), not the `aws-auth` ConfigMap.
- Subnets/SGs were found by the `karpenter.sh/discovery` tag Terraform applied
  (`aws_ec2_tag.subnet_discovery`), not hardcoded IDs.

---

## 3. Scale-down demo — consolidation

```bash
kubectl scale deployment inflate --replicas=0
```

`consolidateAfter: 1m` in the NodePool means: within ~1 minute of a node going
empty/underutilized, Karpenter cordons, drains, and terminates it.

```bash
kubectl get nodes -w
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f | grep -i disrupt
```

You should see the Karpenter-launched node disappear while the original
managed-node-group nodes stay untouched (Karpenter only owns what it launched).

---

## 4. Interruption handling (explain, don't simulate)

The SQS queue + EventBridge rules (`aws_sqs_queue.interruption`,
`aws_cloudwatch_event_rule.interruption` in `modules/karpenter/main.tf`) let
Karpenter drain a node ahead of a real spot reclamation, rebalance
recommendation, or scheduled EC2 maintenance event — instead of the pod just
getting killed with no warning. Not practical to trigger live in a demo; worth
narrating from the code/console (CloudWatch Events → SQS queue `pharma-dev-karpenter-interruption`).

---

## 5. Cleanup

```bash
kubectl delete deployment inflate
```

Karpenter-launched nodes will consolidate away on their own within a minute;
no manual node cleanup needed.
