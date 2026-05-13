output "repo_urls" {
  description = "Map of short name to ECR repository URL"
  value       = { for k, v in aws_ecr_repository.repo : k => v.repository_url }
}

output "repo_arns" {
  description = "Map of short name to ECR repository ARN"
  value       = { for k, v in aws_ecr_repository.repo : k => v.arn }
}
