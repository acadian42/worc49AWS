variable "name_prefix" {
  type = string
}

variable "partition" {
  type        = string
  description = "AWS partition (aws-us-gov for GovCloud)"
}

variable "account_id" {
  type = string
}

variable "region" {
  type = string
}

variable "deletion_window_in_days" {
  type        = number
  description = "Days before a scheduled-for-deletion key is permanently deleted (7–30)"
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
