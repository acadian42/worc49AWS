output "cluster_name" {
  value = aws_ecs_cluster.tines.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.tines.arn
}

output "tines_app_service_name" {
  value = aws_ecs_service.tines_app.name
}

output "tines_sidekiq_service_name" {
  value = aws_ecs_service.tines_sidekiq.name
}

output "tines_app_task_family" {
  description = "Task definition family name (used in aws ecs run-task for DB seed)"
  value       = aws_ecs_task_definition.tines_app.family
}

output "tines_sidekiq_task_family" {
  value = aws_ecs_task_definition.tines_sidekiq.family
}

output "log_group_app" {
  value = aws_cloudwatch_log_group.tines_app.name
}

output "log_group_sidekiq" {
  value = aws_cloudwatch_log_group.tines_sidekiq.name
}
