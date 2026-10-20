output "table_name" {
  description = "Name of the DynamoDB table."
  value       = aws_dynamodb_table.this.name
}

output "table_arn" {
  description = "ARN of the DynamoDB table (grant IAM actions on THIS ARN only)."
  value       = aws_dynamodb_table.this.arn
}

output "table_id" {
  description = "ID of the DynamoDB table (same as name, but Terraform's canonical id output)."
  value       = aws_dynamodb_table.this.id
}

output "hash_key" {
  description = "Partition-key attribute name, echoed back so callers can reference it in code."
  value       = aws_dynamodb_table.this.hash_key
}
