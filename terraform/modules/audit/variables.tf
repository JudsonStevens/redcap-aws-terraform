variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "s3_file_bucket" {
  description = "Name of the S3 file repository bucket (for CloudTrail data events)"
  type        = string
}

variable "log_groups" {
  description = "Map of CloudWatch log group names to archive"
  type        = map(string)
  default     = {}
}

variable "vpc_flow_log_group_name" {
  description = "Name of the VPC flow logs CloudWatch log group"
  type        = string
  default     = ""
}

variable "waf_log_group_name" {
  description = "Name of the WAF CloudWatch log group"
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Email address for alert notifications"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
