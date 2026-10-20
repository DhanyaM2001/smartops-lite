output "repository_urls" {
  description = "Map of repository short name -> full pushable URL (<acct>.dkr.ecr.<region>.amazonaws.com/<name>)."
  value = {
    for name, repo in aws_ecr_repository.this : name => repo.repository_url
  }
}

output "repository_arns" {
  description = "Map of repository short name -> ARN. Useful when scoping IAM policies to specific repos."
  value = {
    for name, repo in aws_ecr_repository.this : name => repo.arn
  }
}

output "registry_id" {
  description = "AWS account ID that owns the registry — same for every repo."
  value       = values(aws_ecr_repository.this)[0].registry_id
}
