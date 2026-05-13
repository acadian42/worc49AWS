output "sg_ids" {
  description = "Map of component name to security group ID"
  value = {
    "tines-alb"    = aws_security_group.alb.id
    "tines-app"    = aws_security_group.app.id
    "tines-sidekiq" = aws_security_group.sidekiq.id
    "tines-db"     = aws_security_group.db.id
    "tines-redis"  = aws_security_group.redis.id
  }
}

output "alb_sg_id"    { value = aws_security_group.alb.id }
output "app_sg_id"    { value = aws_security_group.app.id }
output "sidekiq_sg_id" { value = aws_security_group.sidekiq.id }
output "db_sg_id"     { value = aws_security_group.db.id }
output "redis_sg_id"  { value = aws_security_group.redis.id }
