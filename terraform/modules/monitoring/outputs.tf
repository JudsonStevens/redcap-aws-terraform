output "log_group_name" {
  description = "Name of the main application log group"
  value       = aws_cloudwatch_log_group.application.name
}

output "dashboard_url" {
  description = "URL to the CloudWatch dashboard"
  value       = "https://${data.aws_region.current.name}.console.aws.amazon.com/cloudwatch/home?region=${data.aws_region.current.name}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic for monitoring alerts"
  value       = aws_sns_topic.alerts.arn
}


output "log_groups" {
  description = "Map of log group names"
  value = {
    nginx_access  = aws_cloudwatch_log_group.nginx_access.name
    nginx_error   = aws_cloudwatch_log_group.nginx_error.name
    php_fpm_error = aws_cloudwatch_log_group.php_fpm_error.name
    application   = aws_cloudwatch_log_group.application.name
  }
}

output "cloudwatch_alarms" {
  description = "List of CloudWatch alarm names"
  value = [
    aws_cloudwatch_metric_alarm.alb_response_time.alarm_name,
    aws_cloudwatch_metric_alarm.alb_5xx_errors.alarm_name,
    aws_cloudwatch_metric_alarm.target_group_unhealthy.alarm_name,
    aws_cloudwatch_metric_alarm.redcap_error_rate.alarm_name
  ]
}