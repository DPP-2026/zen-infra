data "aws_partition" "current" {}

locals {
  name                    = "${var.project}-${var.env}"
  interruption_queue_name = "${local.name}-karpenter-interruption"
  oidc_provider_host      = replace(var.oidc_provider_url, "https://", "")

  common_tags = {
    Env     = var.env
    Project = var.project
  }
}

# =============================================================================
# Discovery tags — Karpenter's EC2NodeClass finds subnets/security groups by
# tag rather than by hardcoded ID, so nodes it launches land in the same
# private subnets as the managed node group and reuse the cluster SG.
# =============================================================================
resource "aws_ec2_tag" "subnet_discovery" {
  count       = length(var.private_eks_subnet_ids)
  resource_id = var.private_eks_subnet_ids[count.index]
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

resource "aws_ec2_tag" "cluster_sg_discovery" {
  resource_id = var.cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# =============================================================================
# Karpenter node IAM role — separate from the managed node group role.
# Nodes Karpenter launches join the cluster via an EKS access entry instead
# of the aws-auth ConfigMap.
# =============================================================================
resource "aws_iam_role" "node" {
  name = "${local.name}-karpenter-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${local.name}-karpenter-node-role" })
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "node_AmazonSSMManagedInstanceCore" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lets Karpenter-launched EC2 instances authenticate to the cluster without
# touching the aws-auth ConfigMap (requires API_AND_CONFIG_MAP auth mode).
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"

  tags = local.common_tags
}

# =============================================================================
# Karpenter controller IRSA role — the pod-level identity the controller
# uses to call EC2/IAM/SQS/pricing APIs.
# =============================================================================
data "aws_iam_policy_document" "controller_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_host}:sub"
      values   = ["system:serviceaccount:${var.karpenter_namespace}:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      identifiers = [var.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = "${local.name}-karpenter-controller-role"
  assume_role_policy = data.aws_iam_policy_document.controller_assume_role.json

  tags = merge(local.common_tags, { Name = "${local.name}-karpenter-controller-role" })
}

resource "aws_iam_policy" "controller" {
  name        = "${local.name}-karpenter-controller-policy"
  description = "Permissions Karpenter needs to launch, tag and terminate EC2 capacity for ${var.cluster_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceActions"
        Effect = "Allow"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}::image/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}::snapshot/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:security-group/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:subnet/*",
        ]
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
        ]
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:fleet/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:volume/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:network-interface/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:launch-template/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:spot-instances-request/*",
        ]
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
      {
        # RunInstances/CreateFleet reference an *existing* launch template
        # (created moments earlier by the statement above) rather than
        # creating one, so aws:RequestTag never matches here — only
        # aws:ResourceTag, checked against the tags Karpenter already put
        # on that launch template.
        Sid      = "AllowScopedEC2LaunchTemplateAccessActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:launch-template/*"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedResourceCreationTagging"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:*/*"
        Action   = "ec2:CreateTags"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "ec2:CreateAction"                                         = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
          }
        }
      },
      {
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:instance/*"
        Action   = "ec2:CreateTags"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
      {
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Resource = [
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:instance/*",
          "arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:*:launch-template/*",
        ]
        Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      },
      {
        Sid      = "AllowRegionalReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
        ]
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.aws_region }
        }
      },
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::parameter/aws/service/*"
        Action   = "ssm:GetParameter"
      },
      {
        Sid      = "AllowPricingReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action   = "pricing:GetProducts"
      },
      {
        Sid      = "AllowInterruptionQueueActions"
        Effect   = "Allow"
        Resource = aws_sqs_queue.interruption.arn
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueUrl",
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
        ]
      },
      {
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Resource = aws_iam_role.node.arn
        Action   = "iam:PassRole"
        Condition = {
          StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileCreationActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:instance-profile/*"
        Action   = "iam:CreateInstanceProfile"
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/topology.kubernetes.io/region"             = var.aws_region
          }
          StringLike = { "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*" }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileTagActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:instance-profile/*"
        Action   = "iam:TagInstanceProfile"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"  = "owned"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:instance-profile/*"
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile",
        ]
        Condition = {
          StringEquals = { "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned" }
        }
      },
      {
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:iam::${var.aws_account_id}:instance-profile/*"
        Action   = "iam:GetInstanceProfile"
      },
      {
        Sid      = "AllowAPIServerEndpointDiscovery"
        Effect   = "Allow"
        Resource = "arn:${data.aws_partition.current.partition}:eks:${var.aws_region}:${var.aws_account_id}:cluster/${var.cluster_name}"
        Action   = "eks:DescribeCluster"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "controller" {
  role       = aws_iam_role.controller.name
  policy_arn = aws_iam_policy.controller.arn
}

# =============================================================================
# Interruption handling — Karpenter drains nodes gracefully ahead of spot
# reclamation, rebalance recommendations and scheduled EC2 maintenance by
# consuming these events off an SQS queue instead of polling.
# =============================================================================
resource "aws_sqs_queue" "interruption" {
  name                      = local.interruption_queue_name
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = merge(local.common_tags, { Name = local.interruption_queue_name })
}

resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgeAndHealthEvents"
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.interruption.arn
      }
    ]
  })
}

locals {
  interruption_event_rules = {
    spot_interruption = { source = ["aws.ec2"], "detail-type" = ["EC2 Spot Instance Interruption Warning"] }
    rebalance         = { source = ["aws.ec2"], "detail-type" = ["EC2 Instance Rebalance Recommendation"] }
    state_change      = { source = ["aws.ec2"], "detail-type" = ["EC2 Instance State-change Notification"] }
    scheduled_change  = { source = ["aws.health"], "detail-type" = ["AWS Health Event"] }
  }
}

resource "aws_cloudwatch_event_rule" "interruption" {
  for_each = local.interruption_event_rules

  name = "${local.name}-karpenter-${replace(each.key, "_", "-")}"
  event_pattern = jsonencode({
    source      = each.value.source
    detail-type = each.value["detail-type"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "interruption" {
  for_each = local.interruption_event_rules

  rule      = aws_cloudwatch_event_rule.interruption[each.key].name
  target_id = "${local.name}-karpenter-${replace(each.key, "_", "-")}"
  arn       = aws_sqs_queue.interruption.arn
}

# =============================================================================
# Karpenter controller — installed via Helm so the whole stack (IAM + the
# controller itself) provisions in a single `terraform apply`.
# =============================================================================
resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = var.karpenter_namespace
  create_namespace = true

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  values = [
    yamlencode({
      settings = {
        clusterName       = var.cluster_name
        clusterEndpoint   = var.cluster_endpoint
        interruptionQueue = aws_sqs_queue.interruption.name
      }
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.controller.arn
        }
      }
    })
  ]

  depends_on = [
    aws_eks_access_entry.karpenter_node,
    aws_iam_role_policy_attachment.controller,
  ]
}

# =============================================================================
# Default EC2NodeClass + NodePool — the minimum viable configuration so
# Karpenter can provision capacity out of the box. Application teams can
# layer additional NodePools on top via GitOps for workload-specific needs.
# =============================================================================
resource "kubectl_manifest" "ec2_node_class_default" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      amiFamily = "AL2023"
      amiSelectorTerms = [
        { alias = "al2023@latest" }
      ]
      role = aws_iam_role.node.name
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = var.cluster_name } }
      ]
      tags = merge(local.common_tags, {
        Name                     = "${local.name}-karpenter-node"
        "karpenter.sh/discovery" = var.cluster_name
      })
    }
  })

  depends_on = [helm_release.karpenter]
}

resource "kubectl_manifest" "node_pool_default" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        spec = {
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = var.node_capacity_types },
            { key = "karpenter.k8s.aws/instance-category", operator = "In", values = var.node_instance_categories },
            { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["2"] },
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          expireAfter = "720h"
        }
      }
      limits = { cpu = tostring(var.cpu_limit) }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })

  depends_on = [kubectl_manifest.ec2_node_class_default]
}
