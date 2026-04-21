# DB Subnet Group
resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = var.db_subnet_ids

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db-subnet-group"
  })
}

# Random password for redcap users
resource "random_password" "redcap_user_password" {
  length  = 32
  special = true

  lifecycle {
    ignore_changes = [length, special]
  }
}

# DB Cluster Parameter Group
resource "aws_rds_cluster_parameter_group" "main" {
  name_prefix = "${var.name_prefix}-aurora-params-"
  family      = "aurora-mysql5.7"
  description = "Aurora MySQL parameter group for REDCap"

  parameter {
    name         = "max_allowed_packet"
    value        = "1073741824"
    apply_method = "immediate"
  }

  parameter {
    name         = "query_cache_limit"
    value        = "67108864"
    apply_method = "immediate"
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-aurora-params"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# RDS Aurora Cluster
resource "aws_rds_cluster" "main" {
  cluster_identifier  = "${var.name_prefix}-aurora-cluster"
  engine              = "aurora-mysql"
  engine_version      = "5.7.mysql_aurora.2.11.5"
  database_name       = "redcap"
  master_username     = "master"
  master_password     = var.database_master_password
  snapshot_identifier = var.restore_snapshot_identifier != "" ? var.restore_snapshot_identifier : null

  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.main.name

  backup_retention_period      = 35
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:04:00-sun:05:00"

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [var.db_security_group_id]

  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name_prefix}-aurora-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"

  enabled_cloudwatch_logs_exports = ["error", "general", "slowquery"]

  copy_tags_to_snapshot = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-aurora-cluster"
  })

  lifecycle {
    ignore_changes  = [final_snapshot_identifier]
    prevent_destroy = true
  }
}

# RDS Aurora Instances
resource "aws_rds_cluster_instance" "cluster_instances" {
  count              = var.multi_az_database ? 2 : 1
  identifier         = "${var.name_prefix}-aurora-instance-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = var.database_instance_type
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  publicly_accessible = false

  # Performance Insights requires db.r5+ or db.r6g+ instances.
  # Enable when upgrading from db.t3 instance class.
  performance_insights_enabled = false
  monitoring_interval          = 60
  monitoring_role_arn          = aws_iam_role.rds_monitoring.arn

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-aurora-instance-${count.index + 1}"
  })
}

# KMS Key for RDS encryption
resource "aws_kms_key" "rds" {
  description             = "KMS key for RDS encryption"
  deletion_window_in_days = 30

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-rds-kms-key"
  })
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.name_prefix}-rds"
  target_key_id = aws_kms_key.rds.key_id
}

# IAM Role for RDS Enhanced Monitoring
resource "aws_iam_role" "rds_monitoring" {
  name_prefix = "${var.name_prefix}-rds-monitoring-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# CloudWatch Alarms for RDS
resource "aws_cloudwatch_metric_alarm" "database_cpu" {
  alarm_name          = "${var.name_prefix}-rds-cpu-utilization"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  alarm_description   = "This metric monitors RDS CPU utilization"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main.cluster_identifier
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "database_connections" {
  alarm_name          = "${var.name_prefix}-rds-connection-count"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = "300"
  statistic           = "Average"
  threshold           = "50"
  alarm_description   = "This metric monitors RDS connection count"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.main.cluster_identifier
  }

  tags = var.tags
}

# SNS Topic for database alerts
resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-database-alerts"

  tags = var.tags
}

# Store database credentials in AWS Secrets Manager
resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${var.name_prefix}-database-credentials"
  description = "Database credentials for REDCap"

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    master_username      = aws_rds_cluster.main.master_username
    master_password      = var.database_master_password
    redcap_user_password = random_password.redcap_user_password.result
    endpoint             = aws_rds_cluster.main.endpoint
    port                 = aws_rds_cluster.main.port
    database_name        = aws_rds_cluster.main.database_name
  })
}

# Parameter Store entries for application configuration
resource "aws_ssm_parameter" "db_endpoint" {
  name  = "/${var.name_prefix}/database/endpoint"
  type  = "String"
  value = aws_rds_cluster.main.endpoint

  tags = var.tags
}

resource "aws_ssm_parameter" "db_port" {
  name  = "/${var.name_prefix}/database/port"
  type  = "String"
  value = tostring(aws_rds_cluster.main.port)

  tags = var.tags
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/${var.name_prefix}/database/name"
  type  = "String"
  value = aws_rds_cluster.main.database_name

  tags = var.tags
}