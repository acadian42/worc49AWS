locals {
  ecs_tasks_principal = {
    Service = "ecs-tasks.amazonaws.com"
  }
}

# ── ECS Task Execution Role ───────────────────────────────────────────────────
# Used by ECS/Fargate control plane to: pull images from ECR, inject secrets
# from Secrets Manager, and write logs to CloudWatch.

resource "aws_iam_role" "execution" {
  name = "${var.name_prefix}-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowECSTasksToAssume"
      Effect = "Allow"
      Principal = local.ecs_tasks_principal
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-ecs-execution" })
}

resource "aws_iam_role_policy_attachment" "execution_base" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${var.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "tines-secrets-access"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GetSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = var.secret_arns
      },
      {
        Sid    = "DecryptSecrets"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = [var.kms_secrets_key_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "execution_logs" {
  name = "tines-logs-access"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CreateLogStreams"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = ["arn:${var.partition}:logs:${var.region}:${var.account_id}:log-group:/ecs/${var.name_prefix}*"]
      },
      {
        Sid    = "DecryptLogs"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = [var.kms_logs_key_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "execution_ecr" {
  name = "tines-ecr-pull"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid    = "ECRPull"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = var.ecr_repo_arns
      }
    ]
  })
}

# ── ECS Task Role ─────────────────────────────────────────────────────────────
# Assigned to the running container (not the ECS control plane).
# Extend this role if Tines containers need AWS API access at runtime
# (e.g., S3 for attachments, SES, etc.).

resource "aws_iam_role" "task" {
  name = "${var.name_prefix}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowECSTasksToAssume"
      Effect = "Allow"
      Principal = local.ecs_tasks_principal
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-ecs-task" })
}

# Enables ECS Exec (aws ecs execute-command) for interactive debugging.
# Remove this policy after initial DB seed if you want to lock down further.
resource "aws_iam_role_policy" "task_exec_command" {
  name = "ecs-exec-command"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowSSMMessagesForECSExec"
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = ["*"]
    }]
  })
}

# ── ECS Service-Linked Role ───────────────────────────────────────────────────
# AWS creates this automatically when ECS is first used in an account.
# Set create_ecs_service_linked_role = true only on a brand-new GovCloud account
# that has never used ECS; leave false (default) if ECS has been used before.
resource "aws_iam_service_linked_role" "ecs" {
  count            = var.create_ecs_service_linked_role ? 1 : 0
  aws_service_name = "ecs.amazonaws.com"
}
