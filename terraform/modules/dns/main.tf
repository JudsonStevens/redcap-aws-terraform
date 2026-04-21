# Route53 A record for ALB
resource "aws_route53_record" "main" {
  zone_id         = var.hosted_zone_id
  name            = var.domain_name
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# Route53 A record for test/canary endpoint (same ALB)
resource "aws_route53_record" "test" {
  zone_id         = var.hosted_zone_id
  name            = var.test_domain_name
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = false
  }
}

# Route53 health check for monitoring (always HTTPS for HIPAA deployments)
resource "aws_route53_health_check" "main" {
  fqdn              = "${var.domain_name}.${var.hosted_zone_name}"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/redcap/"
  failure_threshold = "3"
  request_interval  = "30"

  tags = merge(var.tags, {
    Name = "${var.domain_name} Health Check"
  })
}

# CloudWatch alarm for Route53 health check
resource "aws_cloudwatch_metric_alarm" "health_check" {
  alarm_name          = "${var.domain_name}-health-check-alarm"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HealthCheckStatus"
  namespace           = "AWS/Route53"
  period              = "60"
  statistic           = "Minimum"
  threshold           = "1"
  alarm_description   = "This metric monitors health check status"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.main.id
  }

  tags = var.tags
}

# SNS Topic for DNS/health check alerts
resource "aws_sns_topic" "alerts" {
  name = "${var.domain_name}-dns-alerts"

  tags = var.tags
}
