output "controller_role_arn" {
  description = "ARN of the Karpenter controller IRSA role"
  value       = aws_iam_role.controller.arn
}

output "node_role_arn" {
  description = "ARN of the IAM role Karpenter-launched nodes assume"
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "Name of the IAM role Karpenter-launched nodes assume (referenced by EC2NodeClass)"
  value       = aws_iam_role.node.name
}

output "interruption_queue_name" {
  description = "Name of the SQS queue Karpenter consumes interruption/rebalance events from"
  value       = aws_sqs_queue.interruption.name
}

output "interruption_queue_arn" {
  description = "ARN of the SQS queue Karpenter consumes interruption/rebalance events from"
  value       = aws_sqs_queue.interruption.arn
}
