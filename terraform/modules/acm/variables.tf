variable "tines_domain" {
  type        = string
  description = "FQDN to issue or reference the certificate for"
}

variable "certificate_mode" {
  type        = string
  description = "'create' = ACM-managed cert; 'import' = reference a pre-existing ARN"
  default     = "create"
}

variable "route53_zone_id" {
  type        = string
  description = "Route53 zone for DNS validation records (required when certificate_mode = 'create')"
  default     = ""
}

variable "imported_certificate_arn" {
  type        = string
  description = "ARN of existing cert (required when certificate_mode = 'import')"
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
