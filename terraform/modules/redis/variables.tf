variable "name_prefix" {
  type = string
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the ElastiCache subnet group"
}

variable "security_group_id" {
  type = string
}

variable "auth_token" {
  type        = string
  description = "AUTH token for Redis; included in REDIS_URL"
  sensitive   = true
}

variable "node_type" {
  type    = string
  default = "cache.r6g.large"
}

variable "engine_version" {
  type        = string
  description = "Redis engine version. Verify exact patch availability in your GovCloud region."
  default     = "7.2"
}

variable "tags" {
  type    = map(string)
  default = {}
}
