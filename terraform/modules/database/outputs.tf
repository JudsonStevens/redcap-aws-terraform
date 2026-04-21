output "cluster_id" {
  description = "RDS cluster identifier"
  value       = aws_rds_cluster.main.cluster_identifier
}

output "cluster_endpoint" {
  description = "RDS cluster endpoint"
  value       = aws_rds_cluster.main.endpoint
}

output "cluster_reader_endpoint" {
  description = "RDS cluster reader endpoint"
  value       = aws_rds_cluster.main.reader_endpoint
}

output "cluster_port" {
  description = "RDS cluster port"
  value       = aws_rds_cluster.main.port
}

output "cluster_database_name" {
  description = "RDS cluster database name"
  value       = aws_rds_cluster.main.database_name
}

output "cluster_master_username" {
  description = "RDS cluster master username"
  value       = aws_rds_cluster.main.master_username
  sensitive   = true
}

output "secrets_manager_arn" {
  description = "ARN of the Secrets Manager secret containing database credentials"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "kms_key_id" {
  description = "KMS key ID used for RDS encryption"
  value       = aws_kms_key.rds.key_id
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic for database alerts"
  value       = aws_sns_topic.alerts.arn
}

output "redcap_user_password" {
  description = "Generated password for REDCap database user"
  value       = random_password.redcap_user_password.result
  sensitive   = true
}