locals {
  secrets = {
    secret-key-base = var.secret_key_base
    master-key      = var.master_key
    db-password     = var.db_password
    redis-url       = var.redis_url
    smtp-password   = var.smtp_password
  }
}

resource "aws_secretsmanager_secret" "tines" {
  for_each = local.secrets

  name       = "${var.name_prefix}/tines/${each.key}"
  kms_key_id = var.kms_key_arn

  recovery_window_in_days = 7

  tags = merge(var.tags, { Name = "${var.name_prefix}/tines/${each.key}" })
}

resource "aws_secretsmanager_secret_version" "tines" {
  for_each = local.secrets

  secret_id     = aws_secretsmanager_secret.tines[each.key].id
  secret_string = each.value
}
