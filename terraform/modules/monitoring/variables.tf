variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "auto_scaling_group_name" {
  description = "Name of the Auto Scaling Group to monitor"
  type        = string
}

variable "alb_arn_suffix" {
  description = "ARN suffix of the Application Load Balancer"
  type        = string
}

variable "target_group_arn_suffix" {
  description = "ARN suffix of the target group"
  type        = string
}

variable "rds_cluster_id" {
  description = "RDS cluster identifier to monitor"
  type        = string
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}