# =============================================================================
# CloudWatch Logs Archival to S3
# =============================================================================
#
# HIPAA requires 6-year retention for certain records (164.530(j)).
# CloudWatch retention covers operational needs (90-365 days).
# This exports logs daily to S3 with Glacier lifecycle for long-term archival.
#
# Architecture:
#   EventBridge (daily) -> Lambda -> CreateExportTask -> S3 -> Glacier -> Deep Archive

locals {
  # Combine all log groups into a single list for the Lambda
  all_log_groups = compact(concat(
    values(var.log_groups),
    [var.vpc_flow_log_group_name],
    [var.waf_log_group_name],
    [aws_cloudwatch_log_group.cloudtrail.name],
  ))
}

# S3 bucket for log archival
resource "aws_s3_bucket" "log_archive" {
  bucket = "${data.aws_caller_identity.current.account_id}-${var.name_prefix}-log-archive"

  tags = merge(var.tags, {
    Name       = "${var.name_prefix}-log-archive"
    Compliance = "HIPAA"
    Retention  = "6-years"
  })
}

resource "aws_s3_bucket_versioning" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.audit.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id

  rule {
    id     = "archive_to_glacier"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }

    # 6-year retention + 1 month buffer
    expiration {
      days = 2220
    }
  }
}

resource "aws_s3_bucket_policy" "log_archive" {
  bucket = aws_s3_bucket.log_archive.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchExport"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.log_archive.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "AllowCloudWatchExportWrite"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.log_archive.arn}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "DenyInsecureConnections"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.log_archive.arn,
          "${aws_s3_bucket.log_archive.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# Lambda function for daily log export
resource "aws_lambda_function" "log_exporter" {
  function_name = "${var.name_prefix}-log-exporter"
  description   = "Daily export of CloudWatch logs to S3 for HIPAA 6-year retention"
  runtime       = "python3.12"
  handler       = "index.handler"
  timeout       = 300
  memory_size   = 128

  role = aws_iam_role.log_exporter.arn

  filename         = data.archive_file.log_exporter.output_path
  source_code_hash = data.archive_file.log_exporter.output_base64sha256

  environment {
    variables = {
      S3_BUCKET  = aws_s3_bucket.log_archive.id
      LOG_GROUPS = jsonencode(local.all_log_groups)
    }
  }

  tags = var.tags
}

data "archive_file" "log_exporter" {
  type        = "zip"
  output_path = "${path.module}/files/log_exporter.zip"

  source {
    content  = <<-PYTHON
import boto3
import json
import os
import time
from datetime import datetime, timedelta, timezone

def handler(event, context):
    logs = boto3.client('logs')
    bucket = os.environ['S3_BUCKET']
    log_groups = json.loads(os.environ['LOG_GROUPS'])

    # Export yesterday's logs
    yesterday = datetime.now(timezone.utc) - timedelta(days=1)
    start = int(datetime(yesterday.year, yesterday.month, yesterday.day, tzinfo=timezone.utc).timestamp() * 1000)
    end = start + (24 * 60 * 60 * 1000)
    date_prefix = yesterday.strftime('%Y/%m/%d')

    results = []
    for log_group in log_groups:
        if not log_group:
            continue
        # Sanitize log group name for S3 prefix
        safe_name = log_group.strip('/').replace('/', '-')
        prefix = f"{safe_name}/{date_prefix}"

        try:
            response = logs.create_export_task(
                logGroupName=log_group,
                fromTime=start,
                to=end,
                destination=bucket,
                destinationPrefix=prefix,
            )
            task_id = response['taskId']
            results.append({"logGroup": log_group, "taskId": task_id, "status": "started"})
            print(f"Export started: {log_group} -> s3://{bucket}/{prefix} (task: {task_id})")
            # CloudWatch allows only one export task at a time per account
            # Wait for it to complete before starting the next
            while True:
                status = logs.describe_export_tasks(taskId=task_id)
                state = status['exportTasks'][0]['status']['code']
                if state in ('COMPLETED', 'FAILED', 'CANCELLED'):
                    results[-1]['status'] = state.lower()
                    print(f"Export {state}: {log_group}")
                    break
                time.sleep(5)
        except Exception as e:
            results.append({"logGroup": log_group, "error": str(e)})
            print(f"Export failed for {log_group}: {e}")

    return {"exports": results}
PYTHON
    filename = "index.py"
  }
}

# IAM role for Lambda
resource "aws_iam_role" "log_exporter" {
  name_prefix = "${var.name_prefix}-log-export-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "log_exporter" {
  name_prefix = "${var.name_prefix}-log-export-"
  role        = aws_iam_role.log_exporter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateExportTask",
          "logs:DescribeExportTasks"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetBucketAcl"
        ]
        Resource = [
          aws_s3_bucket.log_archive.arn,
          "${aws_s3_bucket.log_archive.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.name_prefix}-log-exporter:*"
      }
    ]
  })
}

# EventBridge rule — run daily at 02:00 UTC
resource "aws_cloudwatch_event_rule" "log_export" {
  name                = "${var.name_prefix}-daily-log-export"
  description         = "Daily CloudWatch Logs export to S3 for HIPAA retention"
  schedule_expression = "cron(0 2 * * ? *)"

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "log_export" {
  rule      = aws_cloudwatch_event_rule.log_export.name
  target_id = "log-exporter-lambda"
  arn       = aws_lambda_function.log_exporter.arn
}

resource "aws_lambda_permission" "log_export" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_exporter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.log_export.arn
}
