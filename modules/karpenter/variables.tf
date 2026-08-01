variable "project" {
  description = "Project name"
  type        = string
}

variable "env" {
  description = "Environment name (dev, qa, prod)"
  type        = string
}

variable "aws_region" {
  description = "AWS region the cluster runs in"
  type        = string
}

variable "aws_account_id" {
  description = "AWS Account ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS OIDC provider (for the controller IRSA role)"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the EKS OIDC provider (for the controller IRSA role)"
  type        = string
}

variable "private_eks_subnet_ids" {
  description = "Private EKS subnet IDs that Karpenter-launched nodes may be placed in"
  type        = list(string)
}

variable "cluster_security_group_id" {
  description = "Security group ID automatically created by EKS for the cluster and managed nodes"
  type        = string
}

variable "karpenter_namespace" {
  description = "Namespace the Karpenter controller is installed into"
  type        = string
  default     = "kube-system"
}

variable "karpenter_version" {
  description = "Version of the Karpenter Helm chart to install"
  type        = string
  default     = "1.11.3"
}

variable "node_instance_categories" {
  description = "EC2 instance categories the default NodePool is allowed to launch"
  type        = list(string)
  default     = ["c", "m", "r"]
}

variable "node_capacity_types" {
  description = "Capacity types (spot, on-demand) the default NodePool is allowed to use"
  type        = list(string)
  default     = ["spot", "on-demand"]
}

variable "cpu_limit" {
  description = "Total vCPU limit across all nodes the default NodePool is allowed to provision"
  type        = number
  default     = 100
}
