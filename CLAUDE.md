# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains Terraform Infrastructure as Code for deploying REDCap (Research Electronic Data Capture) on AWS. REDCap runs on EC2 behind an Application Load Balancer, backed by Aurora MySQL and S3.

The infrastructure is designed with HIPAA controls in mind: encryption at rest and in transit, VPC isolation, CloudTrail, GuardDuty, AWS Config, WAF, and long-term log archival.

## Common Commands

```bash
cd terraform
terraform init       # Initialize Terraform (requires local backend.tf — copy from backend.tf.example)
terraform validate   # Validate configuration syntax
terraform plan       # Preview infrastructure changes
terraform apply      # Deploy infrastructure
terraform destroy    # Tear down infrastructure
```

For upgrades and deployments see `terraform/UPGRADE.md` and `terraform/deploy.sh`.

## Architecture Overview

The infrastructure follows a 3-tier architecture:

1. **Web Tier**: Application Load Balancer with SSL/TLS termination (ACM + WAF)
2. **Application Tier**: Auto Scaling Group with EC2 instances running Nginx/PHP-FPM
3. **Database Tier**: RDS Aurora MySQL (provisioned) with encryption

Key AWS services used:
- **Compute**: EC2, Auto Scaling Groups, Application Load Balancer
- **Storage**: S3 for file storage and Terraform state
- **Database**: RDS Aurora MySQL (provisioned instances)
- **Networking**: VPC with public/private/isolated subnets
- **Security**: Security Groups, IAM roles, KMS encryption, WAF
- **Monitoring**: CloudWatch logs, metrics, and alarms
- **DNS/SSL**: Route53 and ACM for domain management
- **Audit**: CloudTrail, GuardDuty, AWS Config, VPC Flow Logs
- **Secrets**: AWS Secrets Manager for database and app credentials

## Module Structure

- `terraform/modules/networking/` - VPC, subnets, security groups, VPC Flow Logs
- `terraform/modules/compute/` - ALB, ASG, launch template, WAF
- `terraform/modules/database/` - Aurora MySQL cluster
- `terraform/modules/storage/` - S3 buckets, KMS keys
- `terraform/modules/certificate/` - ACM cert with DNS validation
- `terraform/modules/dns/` - Route53 records and health check
- `terraform/modules/monitoring/` - CloudWatch dashboards and alarms
- `terraform/modules/audit/` - CloudTrail, GuardDuty, Config, log archival

## Important Configuration

Key variables to configure in `terraform.tfvars` (see `terraform/environments/prod/terraform.tfvars.example`):

- `project_name` - Resource-naming prefix
- `environment` - Deployment environment (dev/staging/prod)
- `domain_name` / `hosted_zone_id` / `hosted_zone_name` - Route53 domain config
- `database_master_password` - Aurora master password (also written to Secrets Manager)
- `access_cidr` - CIDR range allowed to reach the ALB
- `sendgrid_api_key` - SMTP relay credentials
- `redcap_community_username` / `redcap_community_password` - Used when `redcap_download_method = "api"`

The remote state backend is configured by copying `terraform/backend.tf.example` to `terraform/backend.tf` and editing the bucket name. The real `backend.tf` and `terraform.tfvars` are both gitignored.

## Security Considerations

- All data encrypted at rest and in transit
- No direct SSH access - use AWS Systems Manager Session Manager
- Database in isolated subnet with no internet access
- Security groups follow principle of least privilege
- IAM roles for EC2 instances with minimal permissions
- Automated patching enabled

## Monitoring and Logs

- Application logs: CloudWatch log groups under `/aws/ec2/<name_prefix>/`
- Infrastructure metrics: CloudWatch dashboards
- Database performance: RDS Performance Insights
- Alarms configured for high CPU, memory, disk, and DB health

## Database Management

- Automated backups with 7-day retention
- Point-in-time recovery enabled
- Aurora MySQL (provisioned instances)
- Encrypted with AWS KMS
- Access only from application tier
