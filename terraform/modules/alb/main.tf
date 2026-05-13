data "aws_elb_service_account" "main" {}

# ── S3 bucket for ALB access logs ─────────────────────────────────────────────
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.name_prefix}-tines-alb-logs-${var.account_id}"
  force_destroy = false

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-alb-logs" })
}

resource "aws_s3_bucket_versioning" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  versioning_configuration { status = "Disabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter { prefix = "" }
    expiration { days = 90 }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowALBServiceAccountWrite"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_elb_service_account.main.arn
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/tines-alb/AWSLogs/${var.account_id}/*"
      },
      {
        Sid    = "AllowDeliveryLogs"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alb_logs.arn}/tines-alb/AWSLogs/${var.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Sid    = "AllowDeliveryLogsACLCheck"
        Effect = "Allow"
        Principal = {
          Service = "delivery.logs.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.alb_logs.arn
      }
    ]
  })
}

# ── Application Load Balancer ─────────────────────────────────────────────────
resource "aws_lb" "tines" {
  name               = "${var.name_prefix}-tines"
  internal           = var.internal
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets            = var.subnet_ids

  enable_deletion_protection = true
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = "tines-alb"
    enabled = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-alb" })

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

# ── Target Group ──────────────────────────────────────────────────────────────
resource "aws_lb_target_group" "tines_app" {
  name        = "${var.name_prefix}-tines-app"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-app-tg" })
}

# ── Listeners ─────────────────────────────────────────────────────────────────
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.tines.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tines_app.arn
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-https" })
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.tines.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-http-redirect" })
}
