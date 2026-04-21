# REDCap on AWS — Terraform

This directory contains the Terraform configuration that deploys a HIPAA-oriented REDCap environment on AWS: ALB + ASG + Aurora MySQL + S3, with Route53/ACM, WAF, CloudTrail, GuardDuty, AWS Config, and CloudWatch.

## Prerequisites

- **Terraform** >= 1.0
- **AWS CLI** configured. The provider uses the default credential chain — set `AWS_PROFILE` or any other supported source (env vars, SSO, instance profile).
- **AWS permissions** to create VPC, IAM, EC2, ALB, RDS, S3, KMS, Route53, ACM, Secrets Manager, CloudTrail, GuardDuty, Config, WAF, and Lambda resources.
- **REDCap Consortium** account — required to download the REDCap source.
- **SendGrid** account — used as the SMTP relay for outbound email.
- **Route53 hosted zone** — required if you want automatic DNS + ACM cert provisioning (`use_route53 = true` and `use_acm = true`).

## Quick start

### 1. Create an S3 bucket for remote state

```bash
export STATE_BUCKET=your-terraform-state-bucket

aws s3api create-bucket --bucket "$STATE_BUCKET" --region us-east-1
aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```

Terraform >= 1.11 uses native S3 state locking (`use_lockfile = true`), so no DynamoDB table is needed.

### 2. Configure the backend

```bash
cp backend.tf.example backend.tf
```

Edit `backend.tf` and set the bucket name. `backend.tf` is gitignored so each deployment keeps its own values.

### 3. Configure deployment variables

```bash
cp environments/prod/terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. Required values:

```hcl
# EC2
ec2_key_name             = "my-redcap-key"      # Existing EC2 key pair (optional — Session Manager works without one)
database_master_password = "..."                # 8–41 chars, strong password

# Email (SendGrid SMTP relay)
sendgrid_api_key = "SG.xxxxxxxx"

# REDCap source — API method
redcap_download_method    = "api"
redcap_community_username = "your-consortium-username"
redcap_community_password = "your-consortium-password"
redcap_version            = "latest"

# S3 credentials used by REDCap to write uploaded files
amazon_s3_key    = "AKIA..."
amazon_s3_secret = "..."

# DNS (optional)
use_route53      = true
use_acm          = true
hosted_zone_id   = "Z1234567890ABC"
hosted_zone_name = "example.com"
domain_name      = "redcap"                     # Creates redcap.example.com
```

See `variables.tf` for the full list.

### 4. Deploy

```bash
terraform init
terraform plan
terraform apply
```

First-time deployment takes ~15–20 minutes. Subsequent `apply` runs that only change the launch template are instant, but rolling the new instances into service requires an ASG instance refresh — see [UPGRADE.md](./UPGRADE.md).

### 5. Access REDCap

```bash
terraform output redcap_url
```

Log in as `admin` with the database master password. Change the admin password immediately via Control Center → Administrators.

## DNS and SSL options

### Option A: Route53 + ACM (recommended)

```hcl
use_route53      = true
use_acm          = true
hosted_zone_id   = "Z1234567890ABC"
hosted_zone_name = "example.com"
domain_name      = "redcap"
```

Terraform provisions an ACM certificate for `redcap.example.com`, validates it via DNS in the hosted zone, and creates A/AAAA records pointing at the ALB.

### Option B: Bring your own DNS

```hcl
use_route53 = false
use_acm     = false
```

After `terraform apply`, get the ALB DNS name:

```bash
terraform output alb_dns_name
```

Point a CNAME at it in your DNS provider, then attach an SSL cert to the ALB listener by modifying `modules/compute/main.tf` to reference your cert ARN.

## Configuration reference

Full variable list with types, defaults, and validation rules is in `variables.tf`. Highlights:

| Variable | Purpose | Default |
|---|---|---|
| `aws_region` | Region | `us-east-1` |
| `project_name` | Resource-naming prefix | `redcap` |
| `environment` | Environment tag | `prod` |
| `web_instance_type` | EC2 type for app tier | `t3.medium` |
| `web_asg_min` / `web_asg_max` | ASG bounds | `2` / `4` |
| `database_instance_type` | Aurora instance type | `db.t3.small` |
| `multi_az_database` | Aurora Multi-AZ | `false` |
| `access_cidr` | CIDR allowed to reach ALB | `0.0.0.0/0` |
| `vpc_cidr` | VPC CIDR | `10.1.0.0/16` |
| `redcap_download_method` | `api` or `s3` | `api` |
| `custom_modules_s3_key` | Optional zip of REDCap External Modules | `""` |
| `alert_email` | SNS subscription for infra alarms | `""` |
| `sentry_dsn` | Optional Sentry DSN | `""` |

## Operations

### Access an instance

```bash
aws ssm start-session --target $(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*redcap*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
```

### Tail installation logs during first boot

```bash
sudo tail -f /var/log/user-data.log
```

### Scale the ASG

```hcl
web_asg_min = 3
web_asg_max = 6
```

`terraform apply` to adjust.

### Upgrade REDCap

See [UPGRADE.md](./UPGRADE.md) for the full procedure (tfvars bump → `apply` → ASG instance refresh → `upgrade.php`).

### Canary deployment

`deploy.sh --test` launches a single canary instance on a `redcap-test.*` subdomain, skipping the ASG. See `./deploy.sh` for the full usage.

## Custom REDCap External Modules

To deploy a zip of REDCap External Modules at instance boot:

1. Upload the zip to the REDCap files S3 bucket. The zip must have a top-level `modules/` directory — its contents are copied into `/var/www/html/modules/`.
2. Set `custom_modules_s3_key = "your-modules.zip"` in `terraform.tfvars`.
3. `terraform apply` and trigger an ASG instance refresh to pick up the new modules.

## Security

- **Network:** 3-tier VPC with private app subnets and isolated DB subnets (no internet route). VPC Flow Logs enabled. WAF on the ALB.
- **Encryption:** KMS at rest for EBS, RDS, S3, and Secrets Manager. TLS on the ALB via ACM. TLS for the RDS JDBC connection.
- **Access:** No SSH — all instance access via Session Manager. IAM roles follow least-privilege.
- **Secrets:** Database credentials and app credentials (SendGrid, REDCap Community, Sentry, S3 keys) live in AWS Secrets Manager. The launch template fetches them at boot.
- **Audit:** CloudTrail (multi-region, log-file validation), GuardDuty, AWS Config, long-term S3 archival for 6-year HIPAA retention.

## Troubleshooting

**Installation fails or health check times out:**
- `aws ssm start-session` onto the instance, then `sudo tail -100 /var/log/user-data.log`
- Check that `redcap_community_username`/`redcap_community_password` are correct (for API download method)
- Check that the SendGrid API key is valid

**Database connection errors:**
- Security group rules: app SG → DB SG on 3306 (configured by default)
- Secrets Manager permission on the EC2 role

**ACM certificate stuck in pending validation:**
- Make sure `hosted_zone_id` points at a hosted zone that actually answers queries for `hosted_zone_name`

## Directory layout

```
.
├── main.tf                 # Root module wiring
├── variables.tf            # Input variables
├── outputs.tf              # Outputs
├── providers.tf            # AWS + random provider config
├── backend.tf.example      # Copy to backend.tf and edit
├── deploy.sh               # Apply wrapper + canary deploy
├── UPGRADE.md              # REDCap version upgrade procedure
├── environments/prod/
│   └── terraform.tfvars.example
└── modules/
    ├── networking/         # VPC, subnets, security groups, flow logs
    ├── compute/            # ALB, ASG, launch template, userdata, WAF
    ├── database/           # Aurora MySQL cluster
    ├── storage/            # S3 buckets + KMS
    ├── certificate/        # ACM cert + DNS validation
    ├── dns/                # Route53 records, health check
    ├── monitoring/         # CloudWatch dashboards, alarms
    └── audit/              # CloudTrail, GuardDuty, Config, log archival
```

## License

MIT — see the root [LICENSE](../LICENSE). REDCap itself is licensed separately by Vanderbilt.
