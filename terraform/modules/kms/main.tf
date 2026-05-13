locals {
  root_arn = "arn:${var.partition}:iam::${var.account_id}:root"
}

# ── RDS / Aurora ──────────────────────────────────────────────────────────────
resource "aws_kms_key" "rds" {
  description             = "${var.name_prefix} Aurora PostgreSQL encryption"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = { AWS = local.root_arn }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-rds" })
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.name_prefix}/rds"
  target_key_id = aws_kms_key.rds.id
}

# ── Secrets Manager ───────────────────────────────────────────────────────────
resource "aws_kms_key" "secrets" {
  description             = "${var.name_prefix} Secrets Manager encryption"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = { AWS = local.root_arn }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-secrets" })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name_prefix}/secrets"
  target_key_id = aws_kms_key.secrets.id
}

# ── CloudWatch Logs ───────────────────────────────────────────────────────────
resource "aws_kms_key" "logs" {
  description             = "${var.name_prefix} CloudWatch Logs encryption"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = { AWS = local.root_arn }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${var.partition}:logs:${var.region}:${var.account_id}:log-group:*"
          }
        }
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-logs" })
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${var.name_prefix}/logs"
  target_key_id = aws_kms_key.logs.id
}

# ── ECR ───────────────────────────────────────────────────────────────────────
resource "aws_kms_key" "ecr" {
  description             = "${var.name_prefix} ECR image encryption"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = { AWS = local.root_arn }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-ecr" })
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/${var.name_prefix}/ecr"
  target_key_id = aws_kms_key.ecr.id
}

# ── S3 (ALB access logs, misc) ────────────────────────────────────────────────
resource "aws_kms_key" "s3" {
  description             = "${var.name_prefix} S3 encryption"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = { AWS = local.root_arn }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-s3" })
}

resource "aws_kms_alias" "s3" {
  name          = "alias/${var.name_prefix}/s3"
  target_key_id = aws_kms_key.s3.id
}
