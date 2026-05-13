locals {
  repos = {
    "tines-app"              = "tines/tines-app"
    "tines-command-runner"   = "tines/tines-command-runner"
    "tines-tunnel"           = "tines/tines-tunnel"
  }

  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last ${var.image_retention_count} tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = var.image_retention_count
        }
        action = { type = "expire" }
      }
    ]
  })
}

resource "aws_ecr_repository" "repo" {
  for_each = local.repos

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.tags, { Name = each.value })
}

resource "aws_ecr_lifecycle_policy" "repo" {
  for_each   = aws_ecr_repository.repo
  repository = each.value.name
  policy     = local.lifecycle_policy
}
