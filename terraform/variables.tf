variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "redcap"
}

# EC2 Configuration
variable "ec2_key_name" {
  description = "Name of an EC2 KeyPair for SSH access (leave empty to use Session Manager only)"
  type        = string
  default     = ""
}

variable "web_instance_type" {
  description = "EC2 instance type for web servers"
  type        = string
  default     = "t3.medium"
  validation {
    condition     = can(regex("^(t3|m5|c5|r5)\\.(nano|micro|small|medium|large|xlarge|2xlarge|4xlarge|8xlarge|12xlarge|16xlarge|24xlarge)$", var.web_instance_type))
    error_message = "Instance type must be a valid EC2 instance type."
  }
}

variable "web_asg_min" {
  description = "Minimum number of EC2 instances in Auto Scaling Group"
  type        = number
  default     = 2
  validation {
    condition     = var.web_asg_min >= 1 && var.web_asg_min <= 10
    error_message = "Minimum instances must be between 1 and 10."
  }
}

variable "web_asg_max" {
  description = "Maximum number of EC2 instances in Auto Scaling Group"
  type        = number
  default     = 4
  validation {
    condition     = var.web_asg_max >= 1 && var.web_asg_max <= 30
    error_message = "Maximum instances must be between 1 and 30."
  }
}

variable "php_version" {
  description = "PHP version to install"
  type        = string
  default     = "8.1"
  validation {
    condition     = contains(["7.4", "8.0", "8.1"], var.php_version)
    error_message = "PHP version must be 7.4, 8.0, or 8.1."
  }
}

# Network Configuration
variable "access_cidr" {
  description = "CIDR block for access to REDCap (0.0.0.0/0 for anywhere)"
  type        = string
  default     = "0.0.0.0/0"
  validation {
    condition     = can(cidrhost(var.access_cidr, 0))
    error_message = "Access CIDR must be a valid CIDR block."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.1.0.0/24", "10.1.1.0/24"]
}

variable "app_subnet_cidrs" {
  description = "CIDR blocks for application subnets"
  type        = list(string)
  default     = ["10.1.2.0/24", "10.1.3.0/24"]
}

variable "db_subnet_cidrs" {
  description = "CIDR blocks for database subnets"
  type        = list(string)
  default     = ["10.1.4.0/24", "10.1.5.0/24"]
}

# Database Configuration
variable "database_instance_type" {
  description = "RDS instance type"
  type        = string
  default     = "db.t3.small"
  validation {
    condition     = can(regex("^db\\.(t3|r5)\\.(small|medium|large|xlarge|2xlarge|4xlarge|8xlarge|16xlarge|24xlarge)$", var.database_instance_type))
    error_message = "Database instance type must be a valid RDS instance type."
  }
}

variable "database_master_password" {
  description = "Master password for RDS database"
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.database_master_password) >= 8 && length(var.database_master_password) <= 41
    error_message = "Database password must be between 8 and 41 characters."
  }
}

variable "multi_az_database" {
  description = "Deploy RDS in Multi-AZ configuration"
  type        = bool
  default     = false
}

variable "restore_snapshot_identifier" {
  description = "ARN or identifier of an Aurora cluster snapshot to restore from. Leave empty for a fresh cluster."
  type        = string
  default     = ""
}

# DNS and SSL Configuration
variable "use_route53" {
  description = "Use Route53 for DNS"
  type        = bool
  default     = false
}

variable "use_acm" {
  description = "Use AWS Certificate Manager for SSL"
  type        = bool
  default     = false
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID"
  type        = string
  default     = ""
}

variable "hosted_zone_name" {
  description = "Route53 hosted zone name"
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Domain name for REDCap"
  type        = string
  default     = ""
}

# S3 Credentials (for REDCap file storage)
variable "amazon_s3_key" {
  description = "AWS access key ID for REDCap S3 file storage"
  type        = string
  sensitive   = true
}

variable "amazon_s3_secret" {
  description = "AWS secret access key for REDCap S3 file storage"
  type        = string
  sensitive   = true
}

# Email Configuration (SendGrid)
variable "sendgrid_api_key" {
  description = "SendGrid API key for SMTP relay"
  type        = string
  sensitive   = true
}

# REDCap Application Configuration
variable "redcap_download_method" {
  description = "How to obtain REDCap source (s3 or api)"
  type        = string
  default     = "api"
  validation {
    condition     = contains(["s3", "api"], var.redcap_download_method)
    error_message = "REDCap download method must be 's3' or 'api'."
  }
}

variable "redcap_s3_bucket" {
  description = "S3 bucket containing REDCap source (if using s3 method)"
  type        = string
  default     = ""
}

variable "redcap_s3_key" {
  description = "S3 key for REDCap source file (if using s3 method)"
  type        = string
  default     = ""
}

variable "redcap_s3_bucket_region" {
  description = "Region of S3 bucket containing REDCap source"
  type        = string
  default     = "us-east-1"
}

variable "redcap_community_username" {
  description = "REDCap Community username (if using api method)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "redcap_community_password" {
  description = "REDCap Community password (if using api method)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "redcap_version" {
  description = "REDCap version to install (if using api method)"
  type        = string
  default     = "latest"
}

# Sentry Observability
variable "sentry_dsn" {
  description = "Sentry DSN for error tracking, performance monitoring, and structured logs"
  type        = string
  sensitive   = true
  default     = ""
}

# Alert Notifications
variable "alert_email" {
  description = "Email address for infrastructure alert notifications"
  type        = string
  default     = ""
}

# Canary/Test Deploy
variable "test_domain_name" {
  description = "Subdomain for the canary/test endpoint"
  type        = string
  default     = "redcap-test"
}

# Custom REDCap External Modules
variable "custom_modules_s3_key" {
  description = "S3 key for a zip of REDCap External Modules to drop into /var/www/html/modules/ at instance boot. Leave empty to skip."
  type        = string
  default     = ""
}