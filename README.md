# REDCap on AWS (Terraform)

Infrastructure as Code for deploying [REDCap](https://projectredcap.org/) (Research Electronic Data Capture) on AWS using Terraform. The stack runs REDCap on an EC2 Auto Scaling Group behind an Application Load Balancer, with Aurora MySQL for the database and S3 for file storage. It includes AWS controls commonly used in HIPAA-aligned environments (encryption in transit and at rest, VPC isolation, CloudTrail, GuardDuty, AWS Config, WAF, and log archival).

## HIPAA disclaimer — read this first

**Deploying this Terraform does not make you, your organization, or your REDCap installation HIPAA compliant.** HIPAA compliance is an obligation of the covered entity or business associate operating the system — not of an infrastructure template. This repository is provided "AS IS" with no warranty of compliance, fitness for purpose, or security (see [LICENSE](./LICENSE)).

Technical controls in AWS are only one piece of HIPAA. Before placing any Protected Health Information (PHI) on a deployment of this stack, you — not the authors — are responsible for all of the following:

- Executing a **Business Associate Agreement (BAA) with AWS** through AWS Artifact, and confirming every AWS service you actually use is listed under the [AWS HIPAA Eligible Services Reference](https://aws.amazon.com/compliance/hipaa-eligible-services-reference/). The set of eligible services changes over time; this repo's defaults may drift from that list.
- Completing your own **risk analysis** under 45 CFR §164.308(a)(1)(ii)(A) for the specific workload, data, and threat model.
- Implementing the **administrative safeguards** HIPAA requires: workforce training, access management, sanction policy, incident response, breach notification procedures, contingency planning, periodic review.
- Implementing the **physical safeguards** for any endpoints, backups, or workstations that touch PHI.
- Configuring the **technical safeguards** for your environment correctly — including access control, audit log review, integrity monitoring, encryption key management, and transmission security — and auditing that configuration on an ongoing basis.
- Signing **downstream BAAs** with any subprocessors (SendGrid, Sentry, or any other third party this stack integrates with).
- Ongoing **monitoring, logging review, and independent audit** of all of the above.

If your organization handles PHI, do not deploy this in production without involving your compliance, legal, and security teams. Nothing in this repository, its documentation, or any communication from its authors constitutes legal, compliance, or security advice.

## Looking for the CloudFormation / Elastic Beanstalk version?

This repo is a Terraform-based reimplementation inspired by Vanderbilt's original CloudFormation templates. If you want the Elastic Beanstalk path, see the upstream project:

**[vanderbilt-redcap/redcap-aws-cloudformation](https://github.com/vanderbilt-redcap/redcap-aws-cloudformation)**

## REDCap Consortium requirement

REDCap itself is licensed software from Vanderbilt. You must be a [REDCap Consortium](https://projectredcap.org/) partner to obtain the source. This repo deploys the infrastructure only — it does not redistribute REDCap. At install time the instance downloads REDCap either from the REDCap Community API (using your credentials) or from an S3 bucket you populate with a downloaded release.

## Architecture

Three-tier VPC with public, application, and isolated database subnets:

- **Web tier:** Application Load Balancer (HTTPS, ACM cert, WAF)
- **App tier:** EC2 Auto Scaling Group (Amazon Linux 2023, Nginx + PHP-FPM)
- **Data tier:** Aurora MySQL (provisioned instances, KMS-encrypted)
- **Storage:** S3 buckets for uploaded files (KMS-encrypted, versioned)
- **DNS/TLS:** Route53 + ACM (optional — you can bring your own)
- **Email:** SendGrid SMTP relay (Postfix on the instance)
- **Secrets:** AWS Secrets Manager for database and application credentials
- **Observability:** CloudWatch logs/metrics/alarms, optional Sentry DSN
- **Audit:** CloudTrail, GuardDuty, AWS Config, VPC Flow Logs, WAF logs, long-term S3 archival for HIPAA retention

Access to instances is via AWS Systems Manager Session Manager — no SSH keys exposed to the public internet.

## Prerequisites

- An AWS account with permission to create VPCs, IAM roles, EC2/ASG/ALB, RDS, S3, Route53, ACM, KMS, Secrets Manager, CloudTrail, GuardDuty, Config, and WAF
- Terraform >= 1.0
- AWS CLI configured (set `AWS_PROFILE` or use any supported credential source)
- A REDCap Consortium account (to download REDCap)
- A SendGrid account (for outbound email)
- A Route53 hosted zone, if you want automatic DNS and TLS

## Quick start

```bash
cd terraform

# 1. Configure remote state (edit the bucket name to match your own)
cp backend.tf.example backend.tf
# ...edit backend.tf...

# 2. Configure deployment variables
cp environments/prod/terraform.tfvars.example terraform.tfvars
# ...edit terraform.tfvars with your domain, passwords, API keys...

# 3. Initialize and deploy
terraform init
terraform plan
terraform apply
```

Full setup instructions, variable reference, and post-deploy steps live in [terraform/README.md](./terraform/README.md). Version upgrades are in [terraform/UPGRADE.md](./terraform/UPGRADE.md).

## Repo layout

```
terraform/
  main.tf                 # Root module — wires everything together
  variables.tf            # All root-level input variables
  providers.tf            # AWS + random provider config
  backend.tf.example      # Remote state template — copy to backend.tf
  terraform.tfvars        # Your values (gitignored)
  environments/prod/      # Example tfvars
  modules/
    networking/           # VPC, subnets, security groups, VPC Flow Logs
    compute/              # ALB, ASG, launch template, userdata.sh, WAF
    database/             # Aurora MySQL cluster
    storage/              # S3 file bucket + KMS
    certificate/          # ACM cert (broken out to avoid ALB circular dep)
    dns/                  # Route53 records + health check
    monitoring/           # CloudWatch dashboards, alarms, log groups
    audit/                # CloudTrail, GuardDuty, Config, log archival
  deploy.sh               # Safe wrapper: plan + snapshot + apply, plus canary
  UPGRADE.md              # REDCap version upgrade procedure
```

## License

MIT — see [LICENSE](./LICENSE). Note: REDCap itself is separately licensed by Vanderbilt.
