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
