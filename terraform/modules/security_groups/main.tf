# All security groups are created first with no inline rules.
# Rules are added separately to allow cross-SG references without circular deps.

# ── ALB ───────────────────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name_prefix            = "${var.name_prefix}-alb-"
  vpc_id                 = var.vpc_id
  description            = "Tines Application Load Balancer"
  revoke_rules_on_delete = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group_rule" "alb_ingress_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.alb_ingress_cidrs
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from authorized CIDRs"
}

resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = var.alb_ingress_cidrs
  security_group_id = aws_security_group.alb.id
  description       = "HTTP (redirected to HTTPS by listener rule)"
}

resource "aws_security_group_rule" "alb_egress_app" {
  type                     = "egress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.alb.id
  description              = "Forward to tines-app container port"
}

# ── tines-app ─────────────────────────────────────────────────────────────────
resource "aws_security_group" "app" {
  name_prefix            = "${var.name_prefix}-app-"
  vpc_id                 = var.vpc_id
  description            = "Tines web application (tines-app)"
  revoke_rules_on_delete = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-app" })

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group_rule" "app_ingress_from_alb" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = aws_security_group.app.id
  description              = "Inbound from ALB on port 3000"
}

resource "aws_security_group_rule" "app_egress_db" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.db.id
  security_group_id        = aws_security_group.app.id
  description              = "Outbound to Aurora PostgreSQL"
}

resource "aws_security_group_rule" "app_egress_redis" {
  type                     = "egress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.redis.id
  security_group_id        = aws_security_group.app.id
  description              = "Outbound to ElastiCache Redis"
}

resource "aws_security_group_rule" "app_egress_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app.id
  description       = "Outbound HTTPS (VPC endpoints, external APIs, SMTP TLS)"
}

resource "aws_security_group_rule" "app_egress_smtp" {
  type              = "egress"
  from_port         = 587
  to_port           = 587
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.app.id
  description       = "Outbound SMTP submission"
}

# ── tines-sidekiq ─────────────────────────────────────────────────────────────
resource "aws_security_group" "sidekiq" {
  name_prefix            = "${var.name_prefix}-sidekiq-"
  vpc_id                 = var.vpc_id
  description            = "Tines background worker (tines-sidekiq + tines-command-runner sidecar)"
  revoke_rules_on_delete = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-sidekiq" })

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group_rule" "sidekiq_egress_db" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.db.id
  security_group_id        = aws_security_group.sidekiq.id
  description              = "Outbound to Aurora PostgreSQL"
}

resource "aws_security_group_rule" "sidekiq_egress_redis" {
  type                     = "egress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.redis.id
  security_group_id        = aws_security_group.sidekiq.id
  description              = "Outbound to ElastiCache Redis"
}

resource "aws_security_group_rule" "sidekiq_egress_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.sidekiq.id
  description       = "Outbound HTTPS (VPC endpoints, external APIs)"
}

resource "aws_security_group_rule" "sidekiq_egress_smtp" {
  type              = "egress"
  from_port         = 587
  to_port           = 587
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.sidekiq.id
  description       = "Outbound SMTP submission"
}

# Intra-task localhost traffic (sidekiq <-> command-runner) does not require
# SG rules — containers in the same ECS task share a network namespace.

# ── Aurora PostgreSQL ─────────────────────────────────────────────────────────
resource "aws_security_group" "db" {
  name_prefix            = "${var.name_prefix}-db-"
  vpc_id                 = var.vpc_id
  description            = "Tines Aurora PostgreSQL cluster"
  revoke_rules_on_delete = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-db" })

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group_rule" "db_ingress_from_app" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.db.id
  description              = "PostgreSQL from tines-app"
}

resource "aws_security_group_rule" "db_ingress_from_sidekiq" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.sidekiq.id
  security_group_id        = aws_security_group.db.id
  description              = "PostgreSQL from tines-sidekiq"
}

# ── ElastiCache Redis ─────────────────────────────────────────────────────────
resource "aws_security_group" "redis" {
  name_prefix            = "${var.name_prefix}-redis-"
  vpc_id                 = var.vpc_id
  description            = "Tines ElastiCache Redis replication group"
  revoke_rules_on_delete = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-redis" })

  lifecycle { create_before_destroy = true }
}

resource "aws_security_group_rule" "redis_ingress_from_app" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.app.id
  security_group_id        = aws_security_group.redis.id
  description              = "Redis from tines-app"
}

resource "aws_security_group_rule" "redis_ingress_from_sidekiq" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.sidekiq.id
  security_group_id        = aws_security_group.redis.id
  description              = "Redis from tines-sidekiq"
}
