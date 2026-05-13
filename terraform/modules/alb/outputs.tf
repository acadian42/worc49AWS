output "alb_arn" {
  value = aws_lb.tines.arn
}

output "alb_dns_name" {
  description = "DNS name to point your domain at via A alias or CNAME"
  value       = aws_lb.tines.dns_name
}

output "alb_zone_id" {
  description = "Route53 hosted zone ID of the ALB (used for alias records)"
  value       = aws_lb.tines.zone_id
}

output "target_group_arn" {
  value = aws_lb_target_group.tines_app.arn
}

output "https_listener_arn" {
  value = aws_lb_listener.https.arn
}

output "alb_logs_bucket" {
  value = aws_s3_bucket.alb_logs.id
}
