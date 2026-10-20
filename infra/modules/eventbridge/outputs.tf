output "bus_name" {
  description = "Name of the custom EventBridge bus."
  value       = aws_cloudwatch_event_bus.this.name
}

output "bus_arn" {
  description = "ARN of the custom EventBridge bus — grant PutEvents on THIS ARN only."
  value       = aws_cloudwatch_event_bus.this.arn
}

output "archive_arn" {
  description = "ARN of the archive (null when enable_archive=false)."
  value       = try(aws_cloudwatch_event_archive.this[0].arn, null)
}
