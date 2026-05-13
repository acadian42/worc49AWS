variable "name_prefix" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "alb_ingress_cidrs" {
  type        = list(string)
  description = "CIDRs permitted to reach the ALB on 443 and 80"
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
