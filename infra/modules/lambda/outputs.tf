output "function_name" {
  description = "Deployed Lambda function name."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "Lambda function ARN — pass to EventBridge target / SNS subscription."
  value       = aws_lambda_function.this.arn
}

output "function_invoke_arn" {
  description = "Lambda invoke ARN — used by API Gateway integrations (not needed for EventBridge)."
  value       = aws_lambda_function.this.invoke_arn
}

output "role_name" {
  description = "Name of the execution role (for adding cross-service permissions later)."
  value       = aws_iam_role.lambda.name
}

output "role_arn" {
  description = "ARN of the execution role."
  value       = aws_iam_role.lambda.arn
}

output "log_group_name" {
  description = "CloudWatch Log Group holding the function's logs."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "log_group_arn" {
  description = "ARN of the log group."
  value       = aws_cloudwatch_log_group.lambda.arn
}

output "source_hash" {
  description = "SHA256 of the zipped source — changes on every code change, useful for `terraform output | grep`."
  value       = aws_lambda_function.this.source_code_hash
}
