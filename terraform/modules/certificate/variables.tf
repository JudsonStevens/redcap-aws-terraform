variable "domain_name" {
  description = "Domain name for REDCap application"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID"
  type        = string
}

variable "hosted_zone_name" {
  description = "Route53 hosted zone name"
  type        = string
}

variable "test_domain_name" {
  description = "Subdomain for the canary/test endpoint"
  type        = string
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
