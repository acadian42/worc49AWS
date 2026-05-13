output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "All private subnet IDs (one per AZ). Used by ECS, ALB, RDS, ElastiCache."
  value       = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  value = aws_route_table.private[*].id
}

output "vpc_endpoint_security_group_id" {
  value = aws_security_group.vpc_endpoints.id
}
