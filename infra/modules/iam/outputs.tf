output "role_arn" {
  description = "ARN of the IAM role attached to K3s nodes."
  value       = aws_iam_role.node.arn
}

output "role_name" {
  description = "Name of the IAM role."
  value       = aws_iam_role.node.name
}

output "instance_profile_name" {
  description = "Name of the instance profile — passed to aws_instance.iam_instance_profile."
  value       = aws_iam_instance_profile.node.name
}
