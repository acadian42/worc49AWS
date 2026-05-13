output "secret_arns" {
  description = "Map of secret key name to Secrets Manager ARN"
  value = {
    for k, v in aws_secretsmanager_secret.tines : k => v.arn
  }
  sensitive = true
}

output "secret_key_base_arn" {
  value     = aws_secretsmanager_secret.tines["secret-key-base"].arn
  sensitive = true
}

output "master_key_arn" {
  value     = aws_secretsmanager_secret.tines["master-key"].arn
  sensitive = true
}

output "db_password_arn" {
  value     = aws_secretsmanager_secret.tines["db-password"].arn
  sensitive = true
}

output "redis_url_arn" {
  value     = aws_secretsmanager_secret.tines["redis-url"].arn
  sensitive = true
}

output "smtp_password_arn" {
  value     = aws_secretsmanager_secret.tines["smtp-password"].arn
  sensitive = true
}
