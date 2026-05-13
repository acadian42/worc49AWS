variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "partition" {
  type = string
}

variable "account_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "app_security_group_id" {
  type = string
}

variable "sidekiq_security_group_id" {
  type = string
}

variable "target_group_arn" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "task_role_arn" {
  type = string
}

variable "tines_app_image" {
  type        = string
  description = "Full ECR image URL (with tag) for tines-app"
}

variable "tines_command_runner_image" {
  type        = string
  description = "Full ECR image URL (with tag) for tines-command-runner"
}

variable "kms_logs_key_arn" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# ── Application configuration ─────────────────────────────────────────────────
variable "tines_domain" {
  type = string
}

variable "tenant_email" {
  type = string
}

variable "db_cluster_endpoint" {
  type = string
}

variable "db_reader_endpoint" {
  type = string
}

variable "internal_pypi_url" {
  type = string
}

variable "internal_pypi_host" {
  type = string
}

variable "smtp_address" {
  type    = string
  default = ""
}

variable "smtp_port" {
  type    = number
  default = 587
}

variable "smtp_user" {
  type    = string
  default = ""
}

variable "log_level" {
  type    = string
  default = "INFO"
}

variable "rails_max_threads" {
  type    = number
  default = 16
}

variable "sidekiq_concurrency" {
  type    = number
  default = 12
}

variable "database_pool" {
  type    = number
  default = 24
}

variable "run_script_max_timeout" {
  type    = number
  default = 60
}

variable "openssl_fips_mode" {
  type    = bool
  default = true
}

# ── Secrets (valueFrom ARNs injected by Secrets Manager) ─────────────────────
variable "secret_key_base_arn" {
  type = string
}

variable "master_key_arn" {
  type = string
}

variable "db_password_arn" {
  type = string
}

variable "redis_url_arn" {
  type = string
}

variable "smtp_password_arn" {
  type = string
}

# ── Sizing ────────────────────────────────────────────────────────────────────
variable "app_task_cpu" {
  type    = number
  default = 1024
}

variable "app_task_memory" {
  type    = number
  default = 2048
}

variable "sidekiq_task_cpu" {
  type    = number
  default = 1024
}

variable "sidekiq_task_memory" {
  type    = number
  default = 2048
}

variable "app_desired_count" {
  type    = number
  default = 2
}

variable "sidekiq_desired_count" {
  type    = number
  default = 2
}

variable "enable_command_runner" {
  type    = bool
  default = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
