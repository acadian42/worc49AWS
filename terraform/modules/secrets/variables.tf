variable "name_prefix" {
  type = string
}

variable "kms_key_arn" {
  type        = string
  description = "KMS CMK ARN for encrypting all Secrets Manager secrets"
}

variable "secret_key_base" {
  type        = string
  description = "Rails SECRET_KEY_BASE (128-char hex)"
  sensitive   = true
}

variable "master_key" {
  type        = string
  description = "Tines TINES_MASTER_KEY (64-char hex)"
  sensitive   = true
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "redis_url" {
  type        = string
  description = "Full REDIS_URL including auth token (e.g. rediss://:token@endpoint:6379)"
  sensitive   = true
}

variable "smtp_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
