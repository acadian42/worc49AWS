# GovCloud environment — values confirmed from spec email thread.
# Fill in remaining <STUB> values before running terraform apply.

# ── Region & account ──────────────────────────────────────────────────────────
# Confirmed us-gov-east-1 (AZs listed as 1a/1b/1c throughout emails).
region            = "us-gov-east-1"
use_fips_endpoint = true
name_prefix       = "tines"

# ── Identity ──────────────────────────────────────────────────────────────────
tines_domain = "<STUB: your-tines-hostname.example.gov>"
tenant_email = "<STUB: seed-admin@example.gov>"

# ── Container images ──────────────────────────────────────────────────────────
tines_app_ecr_image            = "<STUB: ECR_URL/tines/tines-app:TAG>"
tines_command_runner_ecr_image = "<STUB: ECR_URL/tines/tines-command-runner:TAG>"

# ── Networking ────────────────────────────────────────────────────────────────
# VPC CIDR confirmed in email: "VPC CIDR Block: 10.105.10.0/24"
vpc_cidr = "10.105.10.0/24"

# 3-AZ spread confirmed: us-gov-east-1a, 1b, 1c.
# RDS Multi-AZ, Aurora, ElastiCache, and ALB fault-tolerance depend on this.
availability_zones = ["us-gov-east-1a", "us-gov-east-1b", "us-gov-east-1c"]

# Single /26 subnet per AZ (no public tier). Agreed with ops team; SGs handle
# app/data isolation. /26 = 64 IPs; Sean estimated ~90-120 worst-case — /26
# confirmed sufficient. Remaining 10.105.10.192/26 reserved for growth.
private_subnet_cidrs = ["10.105.10.0/26", "10.105.10.64/26", "10.105.10.128/26"]

# No public tier — egress routes back through on-prem (Direct Connect).
# Set this to the Transit Gateway ID once the ECM/network team provides it.
transit_gateway_id = "<STUB: tgw-xxxxxxxxxxxxxxxxx>"

# ALB is internal, private subnets — confirmed in email thread.
alb_internal     = true
alb_ingress_cidrs = ["10.105.10.0/24"]

# ── ACM Certificate ───────────────────────────────────────────────────────────
acm_certificate_mode     = "create"
route53_zone_id          = "<STUB: ZONE_ID>"
imported_certificate_arn = ""

# ── Internal PyPI ─────────────────────────────────────────────────────────────
internal_pypi_url  = "<STUB: http://pypi.internal.example.gov/simple>"
internal_pypi_host = "<STUB: pypi.internal.example.gov>"

# ── SMTP ──────────────────────────────────────────────────────────────────────
smtp_address = "<STUB: smtp.internal.example.gov>"
smtp_port    = 587
smtp_user    = "<STUB: tines-mailer@example.gov>"

# ── Database ──────────────────────────────────────────────────────────────────
# Aurora PostgreSQL 14.17 confirmed. Tines requires >= 14.17; 17.x/18.x not
# supported. PG14 EOL Nov 2026 — upgrade roadmap discussion planned with Tines.
db_engine_version        = "14.17"
db_instance_class        = "db.r6g.large"
db_backup_retention_days = 7

# ── Redis ─────────────────────────────────────────────────────────────────────
redis_node_type      = "cache.r6g.large"
redis_engine_version = "7.2"

# ── ECS sizing (Tier 2 baseline) ──────────────────────────────────────────────
app_task_cpu          = 1024
app_task_memory       = 2048
sidekiq_task_cpu      = 1024
sidekiq_task_memory   = 2048
app_desired_count     = 2
sidekiq_desired_count = 2

# ── Feature flags ─────────────────────────────────────────────────────────────
enable_command_runner = true
openssl_fips_mode     = true
log_retention_days    = 30

# ── Tags ──────────────────────────────────────────────────────────────────────
default_tags = {
  Project     = "tines-soar"
  Environment = "govcloud-production"
  ManagedBy   = "terraform"
}
