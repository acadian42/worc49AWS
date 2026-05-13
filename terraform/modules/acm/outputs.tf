output "certificate_arn" {
  description = "ARN of the ACM certificate to attach to the ALB"
  value = (
    var.certificate_mode == "import"
    ? var.imported_certificate_arn
    : aws_acm_certificate.tines[0].arn
  )
}
