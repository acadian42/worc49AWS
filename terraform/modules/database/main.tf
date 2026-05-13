data "aws_partition" "current" {}

resource "aws_db_subnet_group" "tines" {
  name        = "${var.name_prefix}-tines"
  subnet_ids  = var.subnet_ids
  description = "Tines Aurora PostgreSQL subnet group (private subnets only)"

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-db-subnet-group" })
}

resource "aws_rds_cluster_parameter_group" "tines" {
  name        = "${var.name_prefix}-tines-aurora-pg14"
  family      = "aurora-postgresql14"
  description = "Tines Aurora PostgreSQL 14 cluster parameter group"

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-aurora-pg14" })
}

resource "aws_rds_cluster" "tines" {
  cluster_identifier      = "${var.name_prefix}-tines"
  engine                  = "aurora-postgresql"
  engine_version          = var.engine_version
  database_name           = "tines"
  master_username         = "tines"
  master_password         = var.db_password

  db_subnet_group_name            = aws_db_subnet_group.tines.name
  vpc_security_group_ids          = [var.security_group_id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.tines.name

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  backup_retention_period   = var.backup_retention_days
  preferred_backup_window   = "03:00-04:00"
  preferred_maintenance_window = "sun:05:00-sun:06:00"

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-tines-final-snapshot"
  copy_tags_to_snapshot     = true

  enabled_cloudwatch_logs_exports = ["postgresql"]

  lifecycle {
    ignore_changes = [master_password]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines" })
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.name_prefix}-tines-writer"
  cluster_identifier = aws_rds_cluster.tines.id
  instance_class     = var.instance_class
  engine             = aws_rds_cluster.tines.engine
  engine_version     = aws_rds_cluster.tines.engine_version

  db_subnet_group_name = aws_db_subnet_group.tines.name
  publicly_accessible  = false

  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_enhanced_monitoring.arn
  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_key_arn
  auto_minor_version_upgrade      = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-tines-writer"
    Role = "writer"
  })
}

resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.name_prefix}-tines-reader"
  cluster_identifier = aws_rds_cluster.tines.id
  instance_class     = var.instance_class
  engine             = aws_rds_cluster.tines.engine
  engine_version     = aws_rds_cluster.tines.engine_version

  db_subnet_group_name = aws_db_subnet_group.tines.name
  publicly_accessible  = false

  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_enhanced_monitoring.arn
  performance_insights_enabled    = true
  performance_insights_kms_key_id = var.kms_key_arn
  auto_minor_version_upgrade      = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-tines-reader"
    Role = "reader"
  })
}

# ── Enhanced Monitoring Role ──────────────────────────────────────────────────
data "aws_iam_policy_document" "rds_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name               = "${var.name_prefix}-rds-enhanced-monitoring"
  assume_role_policy = data.aws_iam_policy_document.rds_assume.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
