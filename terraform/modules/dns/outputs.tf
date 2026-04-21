output "route53_record_name" {
  description = "FQDN of the Route53 record"
  value       = aws_route53_record.main.fqdn
}

output "route53_record_type" {
  description = "Type of the Route53 record"
  value       = aws_route53_record.main.type
}

output "health_check_id" {
  description = "ID of the Route53 health check"
  value       = aws_route53_health_check.main.id
}

output "health_check_fqdn" {
  description = "FQDN being monitored by the health check"
  value       = aws_route53_health_check.main.fqdn
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic for DNS alerts"
  value       = aws_sns_topic.alerts.arn
}
