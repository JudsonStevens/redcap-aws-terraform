# AWS WAF v2 Web ACL for ALB (HIPAA compliance)
#
# Strategy:
#   - IP reputation + common rules: BLOCK (low false-positive risk)
#   - SQLi rules: COUNT mode (monitor before blocking — REDCap uses SQL-like syntax in forms)
#   - oversize_handling: CONTINUE (inspect first 64KB, allow large uploads through)
#
# To promote SQLi rules to BLOCK after monitoring:
#   Change override_action from { count {} } to { none {} }

resource "aws_wafv2_web_acl" "main" {
  name        = "${var.name_prefix}-waf"
  scope       = "REGIONAL"
  description = "WAF for REDCap ALB - HIPAA compliance"

  default_action {
    allow {}
  }

  # --- BLOCK rules (low false-positive risk) ---

  # AWS IP Reputation List — blocks known malicious IPs
  rule {
    name     = "aws-ip-reputation"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-waf-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  # Common Rule Set — XSS, path traversal, etc.
  rule {
    name     = "aws-common-rules"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # Exclude SizeRestrictions_BODY — REDCap allows up to 2500MB uploads
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }

        # Exclude CrossSiteScripting_BODY — REDCap forms contain HTML-like content
        rule_action_override {
          name = "CrossSiteScripting_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-waf-common-rules"
      sampled_requests_enabled   = true
    }
  }

  # Known Bad Inputs — Log4j, bad user agents, etc.
  rule {
    name     = "aws-known-bad-inputs"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-waf-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  # --- COUNT rules (monitor before blocking) ---

  # SQL Injection — COUNT mode because REDCap calculated fields use SQL-like syntax
  rule {
    name     = "aws-sqli-rules"
    priority = 40

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-waf-sqli-rules"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# Associate WAF with ALB
resource "aws_wafv2_web_acl_association" "main" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

# WAF logging to CloudWatch
resource "aws_wafv2_web_acl_logging_configuration" "main" {
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.main.arn

  # Only log blocked and counted requests (not every allowed request)
  logging_filter {
    default_behavior = "DROP"

    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"

      condition {
        action_condition {
          action = "BLOCK"
        }
      }

      condition {
        action_condition {
          action = "COUNT"
        }
      }
    }
  }
}

# CloudWatch log group for WAF logs
# WAF requires the log group name to start with "aws-waf-logs-"
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name_prefix}"
  retention_in_days = 90

  tags = var.tags
}
