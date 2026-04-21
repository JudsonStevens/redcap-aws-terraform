# Data source for current AWS account ID and region
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# S3 Bucket for REDCap file repository
resource "aws_s3_bucket" "file_repository" {
  bucket = "${data.aws_caller_identity.current.account_id}-${var.name_prefix}-redcap-files"

  tags = merge(var.tags, {
    Name       = "${var.name_prefix}-redcap-files"
    Purpose    = "REDCap File Repository"
    Compliance = "HIPAA"
  })

  lifecycle {
    prevent_destroy = true
  }
}

# S3 Bucket for backups
resource "aws_s3_bucket" "backup" {
  bucket = "${data.aws_caller_identity.current.account_id}-${var.name_prefix}-redcap-backups"

  tags = merge(var.tags, {
    Name       = "${var.name_prefix}-redcap-backups"
    Purpose    = "REDCap Backups"
    Compliance = "HIPAA"
  })
}

# S3 Bucket versioning
resource "aws_s3_bucket_versioning" "file_repository" {
  bucket = aws_s3_bucket.file_repository.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "file_repository" {
  bucket = aws_s3_bucket.file_repository.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# S3 Bucket public access block (HIPAA compliance)
resource "aws_s3_bucket_public_access_block" "file_repository" {
  bucket = aws_s3_bucket.file_repository.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# S3 Bucket logging
resource "aws_s3_bucket_logging" "file_repository" {
  bucket = aws_s3_bucket.file_repository.id

  target_bucket = aws_s3_bucket.backup.id
  target_prefix = "access-logs/file-repository/"
}

resource "aws_s3_bucket_logging" "backup" {
  bucket = aws_s3_bucket.backup.id

  target_bucket = aws_s3_bucket.file_repository.id
  target_prefix = "access-logs/backup/"
}

# S3 Bucket lifecycle configuration
resource "aws_s3_bucket_lifecycle_configuration" "file_repository" {
  bucket = aws_s3_bucket.file_repository.id

  rule {
    id     = "transition_to_ia"
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

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "backup_lifecycle"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 60
      storage_class = "GLACIER"
    }

    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# KMS Key for S3 encryption
resource "aws_kms_key" "s3" {
  description             = "KMS key for S3 bucket encryption"
  deletion_window_in_days = 30

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-s3-kms-key"
  })
}

resource "aws_kms_alias" "s3" {
  name          = "alias/${var.name_prefix}-s3"
  target_key_id = aws_kms_key.s3.key_id
}

# IAM user for REDCap S3 credentials (entered in REDCap admin panel)
resource "aws_iam_user" "redcap_s3" {
  name = "${var.name_prefix}-redcap-s3-user"
  tags = var.tags
}

resource "aws_iam_user_policy" "redcap_s3" {
  name = "${var.name_prefix}-redcap-s3-policy"
  user = aws_iam_user.redcap_s3.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.file_repository.arn,
          "${aws_s3_bucket.file_repository.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.s3.arn
      }
    ]
  })
}

resource "aws_iam_access_key" "redcap_s3" {
  user = aws_iam_user.redcap_s3.name
}

# Store credentials in Secrets Manager for secure retrieval
resource "aws_secretsmanager_secret" "redcap_s3_credentials" {
  name        = "${var.name_prefix}-s3-credentials"
  description = "IAM access key for REDCap S3 file repository (enter in REDCap admin panel)"
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "redcap_s3_credentials" {
  secret_id = aws_secretsmanager_secret.redcap_s3_credentials.id
  secret_string = jsonencode({
    access_key_id     = aws_iam_access_key.redcap_s3.id
    secret_access_key = aws_iam_access_key.redcap_s3.secret
    bucket_name       = aws_s3_bucket.file_repository.bucket
    region            = data.aws_region.current.name
  })
}

# Note: S3 bucket event notifications removed pending proper SNS/SQS
# target configuration. File upload monitoring can be added when needed.

# CloudWatch metric filter for S3 access logs
resource "aws_cloudwatch_log_group" "s3_access" {
  name              = "/aws/s3/${var.name_prefix}/access-logs"
  retention_in_days = 90

  tags = var.tags
}

# S3 Bucket policy for additional security
resource "aws_s3_bucket_policy" "file_repository" {
  bucket = aws_s3_bucket.file_repository.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureConnections"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.file_repository.arn,
          "${aws_s3_bucket.file_repository.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_policy" "backup" {
  bucket = aws_s3_bucket.backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureConnections"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.backup.arn,
          "${aws_s3_bucket.backup.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}