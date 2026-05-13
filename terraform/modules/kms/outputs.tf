output "rds_key_arn" {
  value = aws_kms_key.rds.arn
}

output "secrets_key_arn" {
  value = aws_kms_key.secrets.arn
}

output "logs_key_arn" {
  value = aws_kms_key.logs.arn
}

output "ecr_key_arn" {
  value = aws_kms_key.ecr.arn
}

output "s3_key_arn" {
  value = aws_kms_key.s3.arn
}
