# ── ECS Cluster ───────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "tines" {
  name = "${var.name_prefix}-tines"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines" })
}

resource "aws_ecs_cluster_capacity_providers" "tines" {
  cluster_name       = aws_ecs_cluster.tines.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "tines_app" {
  name              = "/ecs/${var.name_prefix}-tines-app"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_logs_key_arn

  tags = merge(var.tags, { Name = "/ecs/${var.name_prefix}-tines-app" })
}

resource "aws_cloudwatch_log_group" "tines_sidekiq" {
  name              = "/ecs/${var.name_prefix}-tines-sidekiq"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_logs_key_arn

  tags = merge(var.tags, { Name = "/ecs/${var.name_prefix}-tines-sidekiq" })
}

resource "aws_cloudwatch_log_group" "tines_command_runner" {
  count             = var.enable_command_runner ? 1 : 0
  name              = "/ecs/${var.name_prefix}-tines-command-runner"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_logs_key_arn

  tags = merge(var.tags, { Name = "/ecs/${var.name_prefix}-tines-command-runner" })
}

# ── Shared locals ─────────────────────────────────────────────────────────────
locals {
  log_config_app = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.tines_app.name
      awslogs-region        = var.region
      awslogs-stream-prefix = "tines"
    }
  }

  log_config_sidekiq = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.tines_sidekiq.name
      awslogs-region        = var.region
      awslogs-stream-prefix = "tines"
    }
  }

  log_config_command_runner = {
    logDriver = "awslogs"
    options = {
      awslogs-group         = var.enable_command_runner ? aws_cloudwatch_log_group.tines_command_runner[0].name : ""
      awslogs-region        = var.region
      awslogs-stream-prefix = "tines"
    }
  }

  # Environment variables shared by both tines-app and tines-sidekiq.
  # All non-sensitive values are direct environment vars.
  # Sensitive values are injected via Secrets Manager (secrets list below).
  tines_shared_environment = [
    { name = "TINES_DOMAIN",          value = var.tines_domain },
    { name = "TENANT_EMAIL",           value = var.tenant_email },
    { name = "DATABASE_HOST",          value = var.db_cluster_endpoint },
    { name = "DATABASE_READER_HOST",   value = var.db_reader_endpoint },
    { name = "DATABASE_PORT",          value = "5432" },
    { name = "DATABASE_NAME",          value = "tines" },
    { name = "DATABASE_USER",          value = "tines" },
    { name = "DATABASE_POOL",          value = tostring(var.database_pool) },
    { name = "RAILS_MAX_THREADS",      value = tostring(var.rails_max_threads) },
    { name = "SIDEKIQ_CONCURRENCY",    value = tostring(var.sidekiq_concurrency) },
    { name = "RAILS_ENV",              value = "production" },
    { name = "LOG_LEVEL",              value = var.log_level },
    { name = "SMTP_ADDRESS",           value = var.smtp_address },
    { name = "SMTP_PORT",              value = tostring(var.smtp_port) },
    { name = "SMTP_USER_NAME",         value = var.smtp_user },
    { name = "OPENSSL_FIPS_MODE",      value = var.openssl_fips_mode ? "1" : "0" },
  ]

  # Sensitive values injected from Secrets Manager.
  tines_shared_secrets = [
    { name = "SECRET_KEY_BASE",   valueFrom = var.secret_key_base_arn },
    { name = "TINES_MASTER_KEY",  valueFrom = var.master_key_arn },
    { name = "DATABASE_PASSWORD", valueFrom = var.db_password_arn },
    { name = "REDIS_URL",         valueFrom = var.redis_url_arn },
    { name = "SMTP_PASSWORD",     valueFrom = var.smtp_password_arn },
  ]

  # tines-command-runner environment (non-sensitive only; no access to Tines secrets)
  command_runner_environment = [
    { name = "PIP_INDEX_URL",         value = var.internal_pypi_url },
    { name = "PIP_EXTRA_INDEX_URL",   value = var.internal_pypi_url },
    { name = "TRUSTED_HOST",          value = var.internal_pypi_host },
    { name = "UV_NATIVE_TLS",         value = "1" },
    { name = "LOG_LEVEL",             value = var.log_level },
    { name = "RUN_SCRIPT_MAX_TIMEOUT", value = tostring(var.run_script_max_timeout) },
  ]

  # tines-app specific: listens on port 3000
  tines_app_container = {
    name      = "tines-app"
    image     = var.tines_app_image
    essential = true
    command   = ["start-tines-app"]
    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]
    environment      = local.tines_shared_environment
    secrets          = local.tines_shared_secrets
    logConfiguration = local.log_config_app
    healthCheck = {
      command     = ["CMD-SHELL", "curl -sf http://localhost:3000/health || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
    readonlyRootFilesystem = false
    linuxParameters = {
      initProcessEnabled = true
    }
  }

  # tines-sidekiq: no port mapping exposed externally.
  # Adds TINES_COMMAND_RUNNER_HOST=localhost so it calls the sidecar.
  tines_sidekiq_container = {
    name      = "tines-sidekiq"
    image     = var.tines_app_image
    essential = true
    command   = ["start-tines-sidekiq"]
    portMappings = []
    environment = concat(
      local.tines_shared_environment,
      [
        { name = "TINES_COMMAND_RUNNER_HOST", value = "localhost" },
        { name = "RUN_SCRIPT_MAX_TIMEOUT",    value = tostring(var.run_script_max_timeout) },
      ]
    )
    secrets          = local.tines_shared_secrets
    logConfiguration = local.log_config_sidekiq
    healthCheck = {
      command     = ["CMD-SHELL", "pgrep -f sidekiq > /dev/null || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 90
    }
    readonlyRootFilesystem = false
    linuxParameters = {
      initProcessEnabled = true
    }
  }

  # tines-command-runner sidecar.
  # Runs in the same task as sidekiq — shares localhost network namespace.
  # Listens on port 4400 for script execution requests from sidekiq.
  tines_command_runner_container = {
    name      = "tines-command-runner"
    image     = var.tines_command_runner_image
    essential = false  # sidekiq keeps running if command-runner crashes
    portMappings = [{
      containerPort = 4400
      protocol      = "tcp"
    }]
    environment      = local.command_runner_environment
    secrets          = []
    logConfiguration = local.log_config_command_runner
    readonlyRootFilesystem = false
  }

  sidekiq_containers = var.enable_command_runner ? [
    local.tines_sidekiq_container,
    local.tines_command_runner_container,
  ] : [local.tines_sidekiq_container]
}

# ── Task Definition: tines-app ────────────────────────────────────────────────
resource "aws_ecs_task_definition" "tines_app" {
  family                   = "${var.name_prefix}-tines-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.app_task_cpu)
  memory                   = tostring(var.app_task_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([local.tines_app_container])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-app" })
}

# ── Task Definition: tines-sidekiq ───────────────────────────────────────────
resource "aws_ecs_task_definition" "tines_sidekiq" {
  family                   = "${var.name_prefix}-tines-sidekiq"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.sidekiq_task_cpu)
  memory                   = tostring(var.sidekiq_task_memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode(local.sidekiq_containers)

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-sidekiq" })
}

# ── ECS Service: tines-app ────────────────────────────────────────────────────
resource "aws_ecs_service" "tines_app" {
  name                               = "${var.name_prefix}-tines-app"
  cluster                            = aws_ecs_cluster.tines.id
  task_definition                    = aws_ecs_task_definition.tines_app.arn
  desired_count                      = var.app_desired_count
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  health_check_grace_period_seconds  = 60
  enable_execute_command             = true

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.app_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "tines-app"
    container_port   = 3000
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-app-svc" })

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ── ECS Service: tines-sidekiq ────────────────────────────────────────────────
resource "aws_ecs_service" "tines_sidekiq" {
  name                   = "${var.name_prefix}-tines-sidekiq"
  cluster                = aws_ecs_cluster.tines.id
  task_definition        = aws_ecs_task_definition.tines_sidekiq.arn
  desired_count          = var.sidekiq_desired_count
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  enable_execute_command = true

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.sidekiq_security_group_id]
    assign_public_ip = false
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-tines-sidekiq-svc" })

  lifecycle {
    ignore_changes = [desired_count]
  }
}
