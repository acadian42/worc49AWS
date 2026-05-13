resource "aws_elasticache_subnet_group" "tines" {
  name        = "${var.name_prefix}-tines"
  subnet_ids  = var.subnet_ids
  description = "Tines ElastiCache Redis subnet group (private subnets only)"

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-redis-subnet-group" })
}

resource "aws_elasticache_parameter_group" "tines" {
  name        = "${var.name_prefix}-tines-redis7"
  family      = "redis7"
  description = "Tines Redis 7 parameter group"

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-redis7" })
}

resource "aws_elasticache_replication_group" "tines" {
  replication_group_id = "${var.name_prefix}-tines"
  description          = "Tines Redis replication group (primary + 1 replica)"

  engine         = "redis"
  engine_version = var.engine_version
  node_type      = var.node_type

  # Non-cluster mode: 1 shard, 1 replica.
  # Tines/Sidekiq requires non-cluster mode Redis.
  num_cache_clusters         = 2
  automatic_failover_enabled = true
  multi_az_enabled           = true

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = var.auth_token

  subnet_group_name  = aws_elasticache_subnet_group.tines.name
  security_group_ids = [var.security_group_id]
  parameter_group_name = aws_elasticache_parameter_group.tines.name

  snapshot_retention_limit = 1
  snapshot_window          = "04:00-05:00"
  maintenance_window       = "sun:05:00-sun:06:00"

  apply_immediately          = false
  auto_minor_version_upgrade = false

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-redis" })
}
