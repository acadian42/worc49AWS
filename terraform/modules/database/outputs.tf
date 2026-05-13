output "cluster_endpoint" {
  description = "Aurora writer endpoint — use for DATABASE_HOST"
  value       = aws_rds_cluster.tines.endpoint
}

output "reader_endpoint" {
  description = "Aurora reader endpoint — optionally set as DATABASE_READONLY_ENDPOINT"
  value       = aws_rds_cluster.tines.reader_endpoint
}

output "cluster_identifier" {
  value = aws_rds_cluster.tines.cluster_identifier
}

output "cluster_arn" {
  value = aws_rds_cluster.tines.arn
}

output "db_name" {
  value = aws_rds_cluster.tines.database_name
}

output "db_username" {
  value = aws_rds_cluster.tines.master_username
}
