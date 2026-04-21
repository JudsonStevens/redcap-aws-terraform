variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for ALB"
  type        = list(string)
}

variable "app_subnet_ids" {
  description = "List of application subnet IDs for EC2 instances"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "ID of the ALB security group"
  type        = string
}

variable "app_security_group_id" {
  description = "ID of the application security group"
  type        = string
}

variable "ec2_key_name" {
  description = "Name of EC2 Key Pair for SSH access (leave empty to omit)"
  type        = string
  default     = ""
}

variable "web_instance_type" {
  description = "EC2 instance type for web servers"
  type        = string
}

variable "web_asg_min" {
  description = "Minimum number of instances in Auto Scaling Group"
  type        = number
}

variable "web_asg_max" {
  description = "Maximum number of instances in Auto Scaling Group"
  type        = number
}

variable "php_version" {
  description = "PHP version to install"
  type        = string
}

variable "database_endpoint" {
  description = "RDS database endpoint"
  type        = string
}

variable "db_credentials_secret_arn" {
  description = "ARN of the Secrets Manager secret containing database credentials"
  type        = string
}

variable "app_credentials_secret_arn" {
  description = "ARN of the Secrets Manager secret containing application credentials (SendGrid, REDCap)"
  type        = string
}

variable "s3_file_bucket" {
  description = "S3 bucket name for file repository"
  type        = string
}

variable "redcap_download_method" {
  description = "Method to download REDCap (s3 or api)"
  type        = string
}

variable "redcap_s3_bucket" {
  description = "S3 bucket containing REDCap source"
  type        = string
}

variable "redcap_s3_key" {
  description = "S3 key for REDCap source file"
  type        = string
}

variable "redcap_s3_bucket_region" {
  description = "Region of S3 bucket containing REDCap source"
  type        = string
}

variable "redcap_version" {
  description = "REDCap version to install"
  type        = string
}

variable "use_acm" {
  description = "Whether to use ACM for SSL certificates"
  type        = bool
}

variable "use_route53" {
  description = "Whether to use Route53 for DNS"
  type        = bool
}

variable "ssl_certificate_arn" {
  description = "ARN of SSL certificate (if using ACM)"
  type        = string
}

variable "test_ssl_certificate_arn" {
  description = "ARN of the test/canary SSL certificate (if using ACM)"
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Domain name for REDCap"
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

variable "custom_modules_s3_key" {
  description = "S3 key for a zip of REDCap External Modules to drop into /var/www/html/modules/ at instance boot. Leave empty to skip."
  type        = string
  default     = ""
}

variable "s3_kms_key_arn" {
  description = "ARN of the KMS key used for S3 bucket encryption"
  type        = string
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
