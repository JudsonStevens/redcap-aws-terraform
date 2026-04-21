# REDCap Upgrade Guide (Terraform / EC2 + ASG Deployment)

This guide describes how to upgrade REDCap in the Terraform-managed deployment, which uses an EC2 Auto Scaling Group (not Elastic Beanstalk). There is no equivalent to `upgrade-aws-eb.sh` here; upgrades are done by updating Terraform variables and triggering an instance refresh.

---

## Before You Upgrade

### 1. Back up the database

Aurora automated backups are enabled (7-day retention), but take a manual snapshot before any upgrade:

```bash
aws rds create-db-cluster-snapshot \
  --db-cluster-identifier <your-cluster-id> \
  --db-cluster-snapshot-identifier redcap-pre-upgrade-$(date +%Y%m%d)
```

Wait for the snapshot to complete:
```bash
aws rds wait db-cluster-snapshot-available \
  --db-cluster-snapshot-identifier redcap-pre-upgrade-$(date +%Y%m%d)
```

### 2. Note your current version

```bash
mysql -h <db-endpoint> -u master -p redcap \
  -e "SELECT value FROM redcap_config WHERE field_name='redcap_version';"
```

---

## Step 1: Obtain the New REDCap Version

REDCap is licensed software. You must be a registered REDCap partner to download it.

### Option A: Download from REDCap Community (API method)

Set the version in `terraform.tfvars`:
```hcl
redcap_download_method = "api"
redcap_version         = "14.x.x"   # Replace with the target version
```

The `redcap_community_username` and `redcap_community_password` are stored in Secrets Manager (`<name_prefix>-app-credentials`) and are fetched by the instance at boot.

### Option B: Upload to S3 (S3 method)

1. Download the REDCap zip from [https://redcap.vanderbilt.edu](https://redcap.vanderbilt.edu)
2. Upload to your REDCap source S3 bucket:
   ```bash
   aws s3 cp redcap14.x.x.zip s3://<bucket>/redcap14.x.x.zip
   ```
3. Update `terraform.tfvars`:
   ```hcl
   redcap_download_method  = "s3"
   redcap_s3_bucket        = "<your-source-bucket>"
   redcap_s3_key           = "redcap14.x.x.zip"
   ```

---

## Step 2: Apply Terraform Changes

```bash
cd terraform
terraform plan   # Review: should show launch template version change
terraform apply
```

`terraform apply` updates the Launch Template with the new version, but does **not** automatically replace running instances.

---

## Step 3: Trigger a Rolling Instance Refresh

### Option A: Via AWS CLI

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name <name_prefix>-asg \
  --preferences '{"MinHealthyPercentage": 50, "InstanceWarmup": 300}'
```

Monitor progress:
```bash
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name <name_prefix>-asg
```

### Option B: Via AWS Console

1. Go to **EC2 → Auto Scaling Groups → `<name_prefix>-asg`**
2. Click **Instance refresh** → **Start instance refresh**
3. Set minimum healthy percentage to 50%
4. Click **Start**

New instances launch with the updated Launch Template (new REDCap version), pass health checks, then old instances are terminated.

---

## Step 4: Run the REDCap Upgrade

REDCap requires a post-install database upgrade step after each version change.

1. Once the new instances are healthy, browse to:
   ```
   https://<your-domain>/upgrade.php
   ```
2. Log in as a REDCap administrator
3. Follow the on-screen upgrade steps (database schema changes are applied here)
4. Verify the upgrade completed successfully on the Control Center page

---

## Step 5: Verify the Upgrade

- Check the REDCap version at **Control Center → REDCap Version**
- Review CloudWatch logs (`/aws/ec2/<name_prefix>/nginx/error`) for errors
- Check the Route53 health check is green in the AWS console
- Run a smoke test: create a test project, add a record, verify file upload to S3

---

## Rolling Back

If the upgrade fails:

1. **Revert `terraform.tfvars`** to the previous version and run `terraform apply`
2. **Trigger another instance refresh** to roll back the EC2 instances
3. **Restore the database snapshot** if schema changes were applied:
   ```bash
   aws rds restore-db-cluster-from-snapshot \
     --db-cluster-identifier <new-cluster-id> \
     --snapshot-identifier redcap-pre-upgrade-<date> \
     --engine aurora-mysql
   ```
   Update the `database_endpoint` in Parameter Store or re-run Terraform after updating the cluster.

---

## Notes

- The ASG instance refresh respects `min_healthy_percentage = 50`, so at least half the instances stay healthy during the upgrade
- User data runs on every new instance boot — the install script checks whether the DB schema is already installed before re-running
- Database credentials are stored in Secrets Manager (`<name_prefix>-database-credentials`) and are never baked into the Launch Template
