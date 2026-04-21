output "file_repository_bucket_name" {
  description = "Name of the S3 bucket for REDCap file repository"
  value       = aws_s3_bucket.file_repository.bucket
}

output "file_repository_bucket_arn" {
  description = "ARN of the S3 bucket for REDCap file repository"
  value       = aws_s3_bucket.file_repository.arn
}

output "backup_bucket_name" {
  description = "Name of the S3 bucket for backups"
  value       = aws_s3_bucket.backup.bucket
}

output "backup_bucket_arn" {
  description = "ARN of the S3 bucket for backups"
  value       = aws_s3_bucket.backup.arn
}

output "kms_key_id" {
  description = "KMS key ID used for S3 encryption"
  value       = aws_kms_key.s3.key_id
}

output "kms_key_arn" {
  description = "KMS key ARN used for S3 encryption"
  value       = aws_kms_key.s3.arn
}

output "s3_credentials_secret_arn" {
  description = "Secrets Manager ARN containing the IAM credentials for REDCap S3 access"
  value       = aws_secretsmanager_secret.redcap_s3_credentials.arn
}
