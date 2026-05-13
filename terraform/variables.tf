variable "region" {
  type        = string
  description = "AWS GovCloud region — confirmed us-gov-east-1 per spec emails"
  default     = "us-gov-east-1"
}

variable "name_prefix" {
  type        = string
  description = "Short prefix applied to every named resource"
  default     = "tines"
}

variable "use_fips_endpoint" {
  type        = bool
  description = "Route all AWS API calls through FIPS 140-2 validated endpoints"
  default     = true
}

variable "default_tags" {
  type        = map(string)
  description = "Tags applied to every resource via provider default_tags"
  default = {
    Project   = "tines-soar"
    ManagedBy = "terraform"
  }
}

# ── Identity ──────────────────────────────────────────────────────────────────
variable "tines_domain" {
  type        = string
  description = "FQDN that users will access Tines on (e.g. tines.example.gov)"
}

variable "tenant_email" {
  type        = string
  description = "Email address for the first admin user — receives the seed invite"
}

# ── Container images ──────────────────────────────────────────────────────────
variable "tines_app_ecr_image" {
  type        = string
  description = "Full ECR image URL for tines-app, including tag (e.g. 123456.dkr.ecr.us-gov-east-1.amazonaws.com/tines/tines-app:v45.0.0)"
}

variable "tines_command_runner_ecr_image" {
  type        = string
  description = "Full ECR image URL for tines-command-runner, including tag"
}

# ── Networking ────────────────────────────────────────────────────────────────
# VPC CIDR confirmed as 10.105.10.0/24 in spec emails.
variable "vpc_cidr" {
  type    = string
  default = "10.105.10.0/24"
}

# 3-AZ spread confirmed: us-gov-east-1a/b/c.
# RDS Multi-AZ, Aurora, ElastiCache replication, and ALB fault-tolerance
# all depend on this distribution.
variable "availability_zones" {
  type        = list(string)
  description = "Three AZs — confirmed us-gov-east-1a/b/c per spec emails"
  default     = ["us-gov-east-1a", "us-gov-east-1b", "us-gov-east-1c"]
}

# One /26 per AZ, no public tier. Egress through on-prem (Direct Connect).
# /26 = 64 IPs per subnet; 3 × 64 = 192 IPs used within the /24.
# Sean confirmed ~90-120 worst-case IPs per subnet; /26 gives sufficient headroom.
variable "private_subnet_cidrs" {
  type        = list(string)
  description = "One /26 subnet CIDR per AZ (no public tier per spec)"
  default     = ["10.105.10.0/26", "10.105.10.64/26", "10.105.10.128/26"]
}

# Transit Gateway ID provided by network/ECM team for on-prem egress.
# Leave empty until the TGW attachment is provisioned.
variable "transit_gateway_id" {
  type        = string
  description = "TGW ID for on-prem egress default route. Empty = skip route (ECM manages routing)."
  default     = ""
}

variable "alb_internal" {
  type        = bool
  description = "Confirmed internal: ALB lives in private subnets, no public exposure"
  default     = true
}

variable "alb_ingress_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the ALB on port 443/80. Restrict to corporate/VPN range."
  default     = ["10.105.10.0/24"]
}

# ── ACM certificate ───────────────────────────────────────────────────────────
variable "acm_certificate_mode" {
  type        = string
  description = "'create' = request via ACM + Route53 validation; 'import' = supply an existing ARN"
  default     = "create"
  validation {
    condition     = contains(["create", "import"], var.acm_certificate_mode)
    error_message = "acm_certificate_mode must be 'create' or 'import'."
  }
}

variable "route53_zone_id" {
  type        = string
  description = "Route53 hosted zone ID used for ACM DNS validation (required when acm_certificate_mode = 'create')"
  default     = ""
}

variable "imported_certificate_arn" {
  type        = string
  description = "ARN of a pre-existing ACM certificate (required when acm_certificate_mode = 'import')"
  default     = ""
}

# ── Internal PyPI ─────────────────────────────────────────────────────────────
variable "internal_pypi_url" {
  type        = string
  description = "PIP_INDEX_URL for the on-site PyPI repository (e.g. http://pypi.internal.example.gov/simple)"
}

variable "internal_pypi_host" {
  type        = string
  description = "Hostname of the internal PyPI server (used for TRUSTED_HOST env var)"
}

# ── SMTP ──────────────────────────────────────────────────────────────────────
variable "smtp_address" {
  type        = string
  description = "SMTP relay hostname"
  default     = ""
}

variable "smtp_port" {
  type    = number
  default = 587
}

variable "smtp_user" {
  type    = string
  default = ""
}

# ── Database ──────────────────────────────────────────────────────────────────
variable "db_instance_class" {
  type    = string
  default = "db.r6g.large"
}

# Confirmed Aurora PostgreSQL 14.17 (latest minor in the 14.x line).
# Tines requires >= 14.17; 17.x and 18.x are not supported.
# PG14 community EOL: Nov 12 2026. Tines upgrade roadmap engagement planned.
variable "db_engine_version" {
  type    = string
  default = "14.17"
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

# ── Redis ─────────────────────────────────────────────────────────────────────
variable "redis_node_type" {
  type    = string
  default = "cache.r6g.large"
}

variable "redis_engine_version" {
  type        = string
  description = "ElastiCache Redis version. Verify exact patch availability in your GovCloud region."
  default     = "7.2"
}

# ── ECS sizing ────────────────────────────────────────────────────────────────
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

# ── Feature flags ─────────────────────────────────────────────────────────────
variable "enable_command_runner" {
  type        = bool
  description = "Deploy tines-command-runner sidecar alongside tines-sidekiq"
  default     = true
}

variable "openssl_fips_mode" {
  type        = bool
  description = "Enable FIPS-compliant OpenSSL inside Tines containers (OPENSSL_FIPS_MODE=1)"
  default     = true
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "sidekiq_concurrency" {
  type    = number
  default = 12
}

variable "rails_max_threads" {
  type    = number
  default = 16
}

variable "database_pool" {
  type    = number
  default = 24
}

variable "run_script_max_timeout" {
  type    = number
  default = 60
}

variable "log_level" {
  type    = string
  default = "INFO"
}
