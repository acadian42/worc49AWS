output "primary_endpoint" {
  description = "Redis primary endpoint address (host only, no port)"
  value       = aws_elasticache_replication_group.tines.primary_endpoint_address
}

output "reader_endpoint" {
  description = "Redis reader endpoint address"
  value       = aws_elasticache_replication_group.tines.reader_endpoint_address
}

output "port" {
  value = 6379
}

output "replication_group_id" {
  value = aws_elasticache_replication_group.tines.id
}
