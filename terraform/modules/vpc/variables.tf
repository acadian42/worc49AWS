variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "availability_zones" {
  type        = list(string)
  description = "Three AZs for the deployment (us-gov-east-1a/b/c per spec)"
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "One /26 CIDR per AZ. No public tier — egress through on-prem."
}

variable "region" {
  type = string
}

variable "transit_gateway_id" {
  type        = string
  description = "Transit Gateway ID for on-prem egress route. Supplied by network/ECM team. Leave empty to skip route creation."
  default     = ""
}

variable "vpc_endpoint_security_group_ids" {
  type        = list(string)
  description = "Additional security group IDs to attach to Interface-type VPC endpoints"
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
