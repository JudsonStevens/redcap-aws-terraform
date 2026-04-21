# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "nginx_access" {
  name              = "/aws/ec2/${var.name_prefix}/nginx/access"
  retention_in_days = 90

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nginx-access-logs"
  })
}

resource "aws_cloudwatch_log_group" "nginx_error" {
  name              = "/aws/ec2/${var.name_prefix}/nginx/error"
  retention_in_days = 90

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nginx-error-logs"
  })
}

resource "aws_cloudwatch_log_group" "php_fpm_error" {
  name              = "/aws/ec2/${var.name_prefix}/php-fpm/error"
  retention_in_days = 90

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-php-fpm-error-logs"
  })
}

resource "aws_cloudwatch_log_group" "application" {
  name              = "/aws/ec2/${var.name_prefix}/application"
  retention_in_days = 90

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-application-logs"
  })
}

# CloudWatch Dashboard
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix],
            [".", "TargetResponseTime", ".", "."],
            [".", "HTTPCode_Target_2XX_Count", ".", "."],
            [".", "HTTPCode_Target_4XX_Count", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "ALB Metrics"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/AutoScaling", "GroupDesiredCapacity", "AutoScalingGroupName", var.auto_scaling_group_name],
            [".", "GroupInServiceInstances", ".", "."],
            [".", "GroupTotalInstances", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "Auto Scaling Group"
          period  = 300
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6

        properties = {
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBClusterIdentifier", var.rds_cluster_id],
            [".", "DatabaseConnections", ".", "."],
            [".", "ReadLatency", ".", "."],
            [".", "WriteLatency", ".", "."]
          ]
          view    = "timeSeries"
          stacked = false
          region  = data.aws_region.current.name
          title   = "RDS Metrics"
          period  = 300
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 18
        width  = 24
        height = 6

        properties = {
          query  = "SOURCE '${aws_cloudwatch_log_group.nginx_error.name}'\n| fields @timestamp, @message\n| sort @timestamp desc\n| limit 100"
          region = data.aws_region.current.name
          title  = "Recent Nginx Errors"
          view   = "table"
        }
      }
    ]
  })
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "alb_response_time" {
  alarm_name          = "${var.name_prefix}-alb-response-time"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = "300"
  statistic           = "Average"
  threshold           = "5"
  alarm_description   = "This metric monitors ALB response time"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  alarm_name          = "${var.name_prefix}-alb-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = "300"
  statistic           = "Sum"
  threshold           = "10"
  alarm_description   = "This metric monitors ALB 5XX errors"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "target_group_unhealthy" {
  alarm_name          = "${var.name_prefix}-target-group-unhealthy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Average"
  threshold           = "1"
  alarm_description   = "This metric monitors healthy targets in target group"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    TargetGroup  = var.target_group_arn_suffix
    LoadBalancer = var.alb_arn_suffix
  }

  tags = var.tags
}

# Custom metrics for REDCap application
resource "aws_cloudwatch_log_metric_filter" "redcap_errors" {
  name           = "${var.name_prefix}-redcap-errors"
  log_group_name = aws_cloudwatch_log_group.nginx_error.name
  pattern        = "[timestamp, request_id, level=\"ERROR\", ...]"

  metric_transformation {
    name      = "REDCapErrors"
    namespace = "REDCap/Application"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "redcap_error_rate" {
  alarm_name          = "${var.name_prefix}-redcap-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "REDCapErrors"
  namespace           = "REDCap/Application"
  period              = "300"
  statistic           = "Sum"
  threshold           = "5"
  alarm_description   = "This metric monitors REDCap application errors"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# SNS Topic for alerts
resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-monitoring-alerts"

  tags = var.tags
}

# Note: CloudWatch Synthetics canary removed pending creation of the canary
# zip artifact (redcap-health-check.zip). Add back when the artifact exists.

# CloudWatch Log Insights saved queries
resource "aws_cloudwatch_query_definition" "nginx_access_analysis" {
  name = "${var.name_prefix}/nginx-access-analysis"

  log_group_names = [
    aws_cloudwatch_log_group.nginx_access.name
  ]

  query_string = <<EOF
fields @timestamp, @message
| filter @message like /redcap/
| stats count() by bin(5m)
| sort @timestamp desc
EOF
}

resource "aws_cloudwatch_query_definition" "error_analysis" {
  name = "${var.name_prefix}/error-analysis"

  log_group_names = [
    aws_cloudwatch_log_group.nginx_error.name,
    aws_cloudwatch_log_group.php_fpm_error.name
  ]

  query_string = <<EOF
fields @timestamp, @message
| filter @message like /ERROR/
| stats count() by bin(1h)
| sort @timestamp desc
EOF
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}