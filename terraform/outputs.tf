output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer — point your domain A/CNAME here"
  value       = module.alb.alb_dns_name
}

output "alb_arn" {
  value = module.alb.alb_arn
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "tines_app_service_name" {
  value = module.ecs.tines_app_service_name
}

output "tines_sidekiq_service_name" {
  value = module.ecs.tines_sidekiq_service_name
}

output "db_cluster_endpoint" {
  description = "Aurora writer endpoint"
  value       = module.database.cluster_endpoint
}

output "db_reader_endpoint" {
  description = "Aurora reader endpoint — set DATABASE_READONLY_ENDPOINT to offload reads"
  value       = module.database.reader_endpoint
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}


output "ecr_tines_app_url" {
  value = module.ecr.repo_urls["tines-app"]
}

output "ecr_tines_command_runner_url" {
  value = module.ecr.repo_urls["tines-command-runner"]
}

output "secrets_arns" {
  description = "Map of secret names to Secrets Manager ARNs"
  value       = module.secrets.secret_arns
  sensitive   = true
}

output "db_seed_command" {
  description = "AWS CLI command to run the one-off database seed task"
  value = <<-EOT
    aws ecs run-task \
      --cluster ${module.ecs.cluster_name} \
      --task-definition ${module.ecs.tines_app_task_family} \
      --launch-type FARGATE \
      --overrides '{"containerOverrides":[{"name":"tines-app","command":["db:setup"]}]}' \
      --network-configuration "awsvpcConfiguration={subnets=[${join(",", module.vpc.private_subnet_ids)}],securityGroups=[${module.security_groups.sg_ids["tines-app"]}],assignPublicIp=DISABLED}" \
      --region ${var.region}
  EOT
}
