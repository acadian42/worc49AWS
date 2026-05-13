data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition  # "aws-us-gov"
  region     = data.aws_region.current.name
}

# ── Random secret material ────────────────────────────────────────────────────
# These are generated once and stored in Terraform state (encrypted at rest via
# the S3 backend KMS key). For production, consider providing these externally
# via a Vault or HSM and referencing them through data sources instead.

resource "random_id" "db_password" {
  # openssl rand -hex 32 equivalent — 64-character lowercase hex.
  # Tines explicitly requires passwords avoid punctuation other than
  # underscores and dashes. Hex output (0-9, a-f) satisfies this constraint.
  byte_length = 32
}

resource "random_password" "redis_auth_token" {
  # Redis auth tokens: printable ASCII, no spaces or commas, >= 16 chars
  length  = 64
  special = false
  upper   = true
  lower   = true
  numeric = true
}

resource "random_id" "master_key" {
  # 32 bytes → 64-character hex string for TINES_MASTER_KEY
  byte_length = 32
}

resource "random_password" "secret_key_base" {
  # 128-char hex equivalent for SECRET_KEY_BASE
  length  = 128
  special = false
  upper   = false
  lower   = true
  numeric = true
}

resource "random_password" "smtp_password" {
  # Placeholder — override with actual SMTP password in Secrets Manager
  # after apply if your SMTP relay requires one.
  length  = 32
  special = false
}

# ── KMS Keys ──────────────────────────────────────────────────────────────────
module "kms" {
  source = "./modules/kms"

  name_prefix  = var.name_prefix
  partition    = local.partition
  account_id   = local.account_id
  region       = local.region
  tags         = {}
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  name_prefix          = var.name_prefix
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  private_subnet_cidrs = var.private_subnet_cidrs
  region               = var.region
  transit_gateway_id   = var.transit_gateway_id
  # vpc_endpoint_security_group_ids intentionally omitted — the vpc module
  # creates its own vpce SG that allows 443 from the entire VPC CIDR, which
  # covers both tines-app and tines-sidekiq without a circular dependency.

  tags = {}
}

# ── Security Groups ───────────────────────────────────────────────────────────
module "security_groups" {
  source = "./modules/security_groups"

  name_prefix       = var.name_prefix
  vpc_id            = module.vpc.vpc_id
  alb_ingress_cidrs = var.alb_ingress_cidrs

  tags = {}
}

# ── ECR Repositories ──────────────────────────────────────────────────────────
module "ecr" {
  source = "./modules/ecr"

  name_prefix           = var.name_prefix
  kms_key_arn           = module.kms.ecr_key_arn
  image_retention_count = 20

  tags = {}
}

# ── ACM Certificate ───────────────────────────────────────────────────────────
module "acm" {
  source = "./modules/acm"

  tines_domain             = var.tines_domain
  certificate_mode         = var.acm_certificate_mode
  route53_zone_id          = var.route53_zone_id
  imported_certificate_arn = var.imported_certificate_arn

  tags = {}
}

# ── IAM Roles ─────────────────────────────────────────────────────────────────
module "iam" {
  source = "./modules/iam"

  name_prefix = var.name_prefix
  partition   = local.partition
  account_id  = local.account_id
  region      = local.region

  secret_arns = [
    module.secrets.secret_arns["secret-key-base"],
    module.secrets.secret_arns["master-key"],
    module.secrets.secret_arns["db-password"],
    module.secrets.secret_arns["redis-url"],
    module.secrets.secret_arns["smtp-password"],
  ]

  kms_secrets_key_arn = module.kms.secrets_key_arn
  kms_logs_key_arn    = module.kms.logs_key_arn

  ecr_repo_arns = values(module.ecr.repo_arns)

  tags = {}
}

# ── Secrets Manager ───────────────────────────────────────────────────────────
# REDIS_URL is assembled here in root (after both redis endpoint and auth
# token are known) and passed as a single opaque secret string.
module "secrets" {
  source = "./modules/secrets"

  name_prefix = var.name_prefix
  kms_key_arn = module.kms.secrets_key_arn

  secret_key_base = random_password.secret_key_base.result
  master_key      = random_id.master_key.hex
  db_password     = random_id.db_password.hex
  redis_url       = "rediss://:${random_password.redis_auth_token.result}@${module.redis.primary_endpoint}:6379"
  smtp_password   = random_password.smtp_password.result

  tags = {}
}

# ── Aurora PostgreSQL 14 ──────────────────────────────────────────────────────
module "database" {
  source = "./modules/database"

  name_prefix      = var.name_prefix
  subnet_ids       = module.vpc.private_subnet_ids
  security_group_id = module.security_groups.db_sg_id
  kms_key_arn      = module.kms.rds_key_arn
  db_password      = random_id.db_password.hex
  engine_version   = var.db_engine_version
  instance_class   = var.db_instance_class
  backup_retention_days = var.db_backup_retention_days

  tags = {}
}

# ── ElastiCache Redis 7.2 ─────────────────────────────────────────────────────
module "redis" {
  source = "./modules/redis"

  name_prefix       = var.name_prefix
  subnet_ids        = module.vpc.private_subnet_ids
  security_group_id = module.security_groups.redis_sg_id
  auth_token        = random_password.redis_auth_token.result
  node_type         = var.redis_node_type
  engine_version    = var.redis_engine_version

  tags = {}
}

# ── Application Load Balancer ─────────────────────────────────────────────────
module "alb" {
  source = "./modules/alb"

  name_prefix       = var.name_prefix
  vpc_id            = module.vpc.vpc_id
  subnet_ids        = module.vpc.private_subnet_ids  # always private — no public tier per spec
  security_group_id = module.security_groups.alb_sg_id
  certificate_arn   = module.acm.certificate_arn
  internal          = var.alb_internal
  region            = local.region
  account_id        = local.account_id
  partition         = local.partition

  tags = {}
}

# ── ECS Cluster + Task Definitions + Services ─────────────────────────────────
module "ecs" {
  source = "./modules/ecs"

  name_prefix = var.name_prefix
  region      = local.region
  partition   = local.partition
  account_id  = local.account_id

  private_subnet_ids        = module.vpc.private_subnet_ids
  app_security_group_id     = module.security_groups.app_sg_id
  sidekiq_security_group_id = module.security_groups.sidekiq_sg_id
  target_group_arn          = module.alb.target_group_arn
  execution_role_arn        = module.iam.execution_role_arn
  task_role_arn             = module.iam.task_role_arn

  tines_app_image              = var.tines_app_ecr_image
  tines_command_runner_image   = var.tines_command_runner_ecr_image

  kms_logs_key_arn   = module.kms.logs_key_arn
  log_retention_days = var.log_retention_days

  # Application config
  tines_domain        = var.tines_domain
  tenant_email        = var.tenant_email
  db_cluster_endpoint = module.database.cluster_endpoint
  db_reader_endpoint  = module.database.reader_endpoint
  internal_pypi_url   = var.internal_pypi_url
  internal_pypi_host  = var.internal_pypi_host
  smtp_address        = var.smtp_address
  smtp_port           = var.smtp_port
  smtp_user           = var.smtp_user
  log_level           = var.log_level
  rails_max_threads   = var.rails_max_threads
  sidekiq_concurrency = var.sidekiq_concurrency
  database_pool       = var.database_pool
  run_script_max_timeout = var.run_script_max_timeout
  openssl_fips_mode   = var.openssl_fips_mode

  # Secret ARNs (injected into containers via ECS secrets mechanism)
  secret_key_base_arn = module.secrets.secret_key_base_arn
  master_key_arn      = module.secrets.master_key_arn
  db_password_arn     = module.secrets.db_password_arn
  redis_url_arn       = module.secrets.redis_url_arn
  smtp_password_arn   = module.secrets.smtp_password_arn

  # Sizing
  app_task_cpu          = var.app_task_cpu
  app_task_memory       = var.app_task_memory
  sidekiq_task_cpu      = var.sidekiq_task_cpu
  sidekiq_task_memory   = var.sidekiq_task_memory
  app_desired_count     = var.app_desired_count
  sidekiq_desired_count = var.sidekiq_desired_count
  enable_command_runner = var.enable_command_runner

  tags = {}
}
