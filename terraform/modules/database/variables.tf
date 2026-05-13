variable "name_prefix" {
  type = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the DB subnet group"
}

variable "security_group_id" {
  type = string
}

variable "kms_key_arn" {
  type        = string
  description = "KMS CMK ARN for Aurora storage encryption"
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "engine_version" {
  type    = string
  default = "14.17"
}

variable "instance_class" {
  type    = string
  default = "db.r6g.large"
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}
