locals {
  name_prefix = "${var.project_name}-${var.environment}"
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Data sources for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# VPC and Networking
module "networking" {
  source = "./modules/networking"

  name_prefix         = local.name_prefix
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
  app_subnet_cidrs    = var.app_subnet_cidrs
  db_subnet_cidrs     = var.db_subnet_cidrs
  availability_zones  = data.aws_availability_zones.available.names
  access_cidr         = var.access_cidr
  use_acm             = var.use_acm
  use_route53         = var.use_route53

  tags = local.common_tags
}

# ACM Certificate — runs before compute (no dependency on ALB)
module "certificate" {
  source = "./modules/certificate"
  count  = var.use_route53 && var.use_acm ? 1 : 0

  domain_name      = var.domain_name
  hosted_zone_id   = var.hosted_zone_id
  hosted_zone_name = var.hosted_zone_name
  test_domain_name = var.test_domain_name

  tags = local.common_tags
}

# S3 Storage
module "storage" {
  source = "./modules/storage"

  name_prefix = local.name_prefix
  tags        = local.common_tags
}

# RDS Database
module "database" {
  source = "./modules/database"

  name_prefix                 = local.name_prefix
  vpc_id                      = module.networking.vpc_id
  db_subnet_ids               = module.networking.db_subnet_ids
  db_security_group_id        = module.networking.db_security_group_id
  database_instance_type      = var.database_instance_type
  database_master_password    = var.database_master_password
  multi_az_database           = var.multi_az_database
  restore_snapshot_identifier = var.restore_snapshot_identifier

  tags = local.common_tags
}

# Application credentials stored in Secrets Manager (no static keys in user data)
resource "aws_secretsmanager_secret" "app_credentials" {
  name        = "${local.name_prefix}-app-credentials"
  description = "Application credentials for REDCap (SendGrid, REDCap Community)"

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "app_credentials" {
  secret_id = aws_secretsmanager_secret.app_credentials.id
  secret_string = jsonencode({
    sendgrid_api_key          = var.sendgrid_api_key
    redcap_community_username = var.redcap_community_username
    redcap_community_password = var.redcap_community_password
    sentry_dsn                = var.sentry_dsn
    amazon_s3_key             = var.amazon_s3_key
    amazon_s3_secret          = var.amazon_s3_secret
  })
}

# EC2 Compute Resources
module "compute" {
  source = "./modules/compute"

  name_prefix           = local.name_prefix
  vpc_id                = module.networking.vpc_id
  public_subnet_ids     = module.networking.public_subnet_ids
  app_subnet_ids        = module.networking.app_subnet_ids
  alb_security_group_id = module.networking.alb_security_group_id
  app_security_group_id = module.networking.app_security_group_id

  # EC2 Configuration
  ec2_key_name      = var.ec2_key_name
  web_instance_type = var.web_instance_type
  web_asg_min       = var.web_asg_min
  web_asg_max       = var.web_asg_max

  # Application Configuration
  php_version                = var.php_version
  database_endpoint          = module.database.cluster_endpoint
  db_credentials_secret_arn  = module.database.secrets_manager_arn
  app_credentials_secret_arn = aws_secretsmanager_secret.app_credentials.arn
  s3_file_bucket             = module.storage.file_repository_bucket_name
  s3_kms_key_arn             = module.storage.kms_key_arn

  # REDCap Configuration
  redcap_download_method  = var.redcap_download_method
  redcap_s3_bucket        = var.redcap_s3_bucket
  redcap_s3_key           = var.redcap_s3_key
  redcap_s3_bucket_region = var.redcap_s3_bucket_region
  redcap_version          = var.redcap_version

  # Custom REDCap External Modules
  custom_modules_s3_key = var.custom_modules_s3_key

  # Canary/test deploy
  test_domain_name = var.test_domain_name

  # SSL Configuration
  use_acm                  = var.use_acm
  use_route53              = var.use_route53
  ssl_certificate_arn      = var.use_route53 && var.use_acm ? module.certificate[0].certificate_arn : ""
  test_ssl_certificate_arn = var.use_route53 && var.use_acm ? module.certificate[0].test_certificate_arn : ""
  domain_name              = var.domain_name
  hosted_zone_name         = var.hosted_zone_name

  tags = local.common_tags
}

# DNS and Route53 records (requires compute ALB to exist)
module "dns" {
  source = "./modules/dns"
  count  = var.use_route53 ? 1 : 0

  domain_name      = var.domain_name
  hosted_zone_id   = var.hosted_zone_id
  hosted_zone_name = var.hosted_zone_name
  test_domain_name = var.test_domain_name
  alb_dns_name     = module.compute.alb_dns_name
  alb_zone_id      = module.compute.alb_zone_id

  tags = local.common_tags
}

# Audit — CloudTrail, GuardDuty, AWS Config (HIPAA compliance)
module "audit" {
  source = "./modules/audit"

  name_prefix    = local.name_prefix
  s3_file_bucket = module.storage.file_repository_bucket_name
  alert_email    = var.alert_email

  # Log groups for archival to S3 (HIPAA 6-year retention)
  log_groups              = module.monitoring.log_groups
  vpc_flow_log_group_name = "/aws/vpc/flowlogs/${local.name_prefix}"
  waf_log_group_name      = "aws-waf-logs-${local.name_prefix}"

  tags = local.common_tags
}

# SNS email subscriptions for all alert topics
resource "aws_sns_topic_subscription" "database_alerts" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = module.database.sns_topic_arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "monitoring_alerts" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = module.monitoring.sns_topic_arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "dns_alerts" {
  count = var.alert_email != "" && var.use_route53 ? 1 : 0

  topic_arn = module.dns[0].sns_topic_arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# CloudWatch Monitoring
module "monitoring" {
  source = "./modules/monitoring"

  name_prefix             = local.name_prefix
  auto_scaling_group_name = module.compute.auto_scaling_group_name
  alb_arn_suffix          = module.compute.alb_arn_suffix
  target_group_arn_suffix = module.compute.target_group_arn_suffix
  rds_cluster_id          = module.database.cluster_id

  tags = local.common_tags
}
