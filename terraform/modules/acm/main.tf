resource "aws_acm_certificate" "tines" {
  count = var.certificate_mode == "create" ? 1 : 0

  domain_name       = var.tines_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, { Name = var.tines_domain })
}

resource "aws_route53_record" "validation" {
  for_each = (
    var.certificate_mode == "create" && var.route53_zone_id != ""
    ? {
        for dvo in aws_acm_certificate.tines[0].domain_validation_options :
        dvo.domain_name => {
          name   = dvo.resource_record_name
          record = dvo.resource_record_value
          type   = dvo.resource_record_type
        }
      }
    : {}
  )

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = var.route53_zone_id
}

resource "aws_acm_certificate_validation" "tines" {
  count = var.certificate_mode == "create" && var.route53_zone_id != "" ? 1 : 0

  certificate_arn         = aws_acm_certificate.tines[0].arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}
