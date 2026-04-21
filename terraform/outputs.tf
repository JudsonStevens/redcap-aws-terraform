output "vpc_id" {
  description = "ID of the VPC"
  value       = module.networking.vpc_id
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = module.compute.alb_dns_name
}

output "alb_zone_id" {
  description = "Zone ID of the Application Load Balancer"
  value       = module.compute.alb_zone_id
}

output "database_endpoint" {
  description = "RDS cluster endpoint"
  value       = module.database.cluster_endpoint
  sensitive   = true
}

output "database_port" {
  description = "RDS cluster port"
  value       = module.database.cluster_port
}

output "s3_file_repository_bucket" {
  description = "S3 bucket for REDCap file repository"
  value       = module.storage.file_repository_bucket_name
}

output "s3_backup_bucket" {
  description = "S3 bucket for backups"
  value       = module.storage.backup_bucket_name
}

output "redcap_url" {
  description = "URL to access REDCap application"
  value = var.use_route53 ? (
    var.use_acm ?
    "https://${var.domain_name}.${var.hosted_zone_name}" :
    "http://${var.domain_name}.${var.hosted_zone_name}"
    ) : (
    var.use_acm ?
    "https://${module.compute.alb_dns_name}" :
    "http://${module.compute.alb_dns_name}"
  )
}

output "ssl_certificate_arn" {
  description = "ARN of the SSL certificate (if created)"
  value       = var.use_route53 && var.use_acm ? module.certificate[0].certificate_arn : null
}

output "auto_scaling_group_name" {
  description = "Name of the Auto Scaling Group"
  value       = module.compute.auto_scaling_group_name
}

output "launch_template_id" {
  description = "ID of the EC2 Launch Template"
  value       = module.compute.launch_template_id
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch Log Group"
  value       = module.monitoring.log_group_name
}

output "rds_cluster_id" {
  description = "RDS cluster identifier (used by deploy.sh for pre-apply snapshots)"
  value       = module.database.cluster_id
}

output "test_target_group_arn" {
  description = "ARN of the test/canary target group"
  value       = module.compute.test_target_group_arn
}

output "test_url" {
  description = "URL for the canary/test endpoint"
  value       = var.use_route53 && var.use_acm ? "https://${var.test_domain_name}.${var.hosted_zone_name}" : ""
}