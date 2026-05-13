variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type        = string
  description = "VPC ID for the target group"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnets for the ALB. Use public subnets for internet-facing, private for internal."
}

variable "security_group_id" {
  type = string
}

variable "certificate_arn" {
  type = string
}

variable "internal" {
  type        = bool
  description = "true = internal ALB (recommended for GovCloud)"
  default     = true
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "partition" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
