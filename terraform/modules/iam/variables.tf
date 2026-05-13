variable "name_prefix" {
  type = string
}

variable "partition" {
  type        = string
  description = "AWS partition (aws-us-gov)"
}

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "secret_arns" {
  type        = list(string)
  description = "Secrets Manager ARNs the ECS execution role must be able to read"
}

variable "kms_secrets_key_arn" {
  type        = string
  description = "KMS CMK ARN used to encrypt Secrets Manager secrets"
}

variable "kms_logs_key_arn" {
  type        = string
  description = "KMS CMK ARN used to encrypt CloudWatch log groups"
}

variable "ecr_repo_arns" {
  type        = list(string)
  description = "ECR repository ARNs the execution role needs pull access to"
}

variable "create_ecs_service_linked_role" {
  type        = bool
  description = "Set true only on a new GovCloud account that has never run ECS. Usually false."
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
