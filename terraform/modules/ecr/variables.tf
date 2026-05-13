variable "name_prefix" {
  type = string
}

variable "kms_key_arn" {
  type        = string
  description = "KMS CMK ARN for ECR image encryption at rest"
}

variable "image_retention_count" {
  type        = number
  description = "Maximum number of tagged images to keep per repository"
  default     = 20
}

variable "tags" {
  type    = map(string)
  default = {}
}
