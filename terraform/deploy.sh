#!/usr/bin/env bash
#
# deploy.sh — Safe wrapper around terraform apply + canary deploy
#
# Usage:
#   ./deploy.sh              # plan + snapshot + apply
#   ./deploy.sh -auto        # skip the confirmation prompt (for CI)
#   ./deploy.sh plan         # just run terraform plan (no snapshot)
#   ./deploy.sh --test       # launch canary instance at redcap-test.*
#   ./deploy.sh --promote    # ASG refresh + terminate canary
#   ./deploy.sh --abort      # terminate canary, no prod changes
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

CANARY_TAG_KEY="DeploymentRole"
CANARY_TAG_VALUE="canary-test"

# ── Read Terraform outputs ────────────────────────────────────────────
get_cluster_id() {
    terraform output -raw rds_cluster_id 2>/dev/null || true
}

get_test_tg_arn() {
    terraform output -raw test_target_group_arn 2>/dev/null || true
}

get_test_url() {
    terraform output -raw test_url 2>/dev/null || true
}

get_asg_name() {
    terraform output -raw auto_scaling_group_name 2>/dev/null || true
}

get_launch_template_id() {
    terraform output -raw launch_template_id 2>/dev/null || true
}

get_domain_name() {
    # Production FQDN for the nginx Host header override
    terraform output -raw redcap_url 2>/dev/null | sed 's|https://||; s|http://||; s|/$||' || true
}

# ── Find existing canary instance ─────────────────────────────────────
find_canary_instance() {
    aws ec2 describe-instances \
        --filters \
            "Name=tag:${CANARY_TAG_KEY},Values=${CANARY_TAG_VALUE}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' \
        --output text 2>/dev/null | head -1
}

# ── Create a manual RDS snapshot ─────────────────────────────────────
create_snapshot() {
    local cluster_id="$1"
    local timestamp
    timestamp=$(date -u +"%Y%m%d-%H%M%S")
    local snapshot_id="pre-deploy-${cluster_id}-${timestamp}"

    info "Creating RDS cluster snapshot: $snapshot_id"
    aws rds create-db-cluster-snapshot \
        --db-cluster-identifier "$cluster_id" \
        --db-cluster-snapshot-identifier "$snapshot_id" \
        --tags "Key=CreatedBy,Value=deploy-script" "Key=Purpose,Value=pre-deploy-backup" \
        >/dev/null

    info "Waiting for snapshot to become available..."
    aws rds wait db-cluster-snapshot-available \
        --db-cluster-snapshot-identifier "$snapshot_id"

    info "Snapshot $snapshot_id is ready."
}

# ── Canary: --test ────────────────────────────────────────────────────
do_test() {
    info "Starting canary test deployment..."

    # Check no existing canary
    local existing
    existing=$(find_canary_instance)
    if [[ -n "$existing" ]]; then
        error "A canary instance already exists: $existing"
        error "Run './deploy.sh --abort' to clean up first."
        exit 1
    fi

    local test_tg_arn launch_template_id prod_fqdn test_url
    test_tg_arn=$(get_test_tg_arn)
    launch_template_id=$(get_launch_template_id)
    prod_fqdn=$(get_domain_name)
    test_url=$(get_test_url)

    if [[ -z "$test_tg_arn" || -z "$launch_template_id" ]]; then
        error "Could not read test_target_group_arn or launch_template_id from Terraform outputs."
        error "Run 'terraform apply' first to create the canary infrastructure."
        exit 1
    fi

    # Get a subnet from the ASG config
    local asg_name subnet_id
    asg_name=$(get_asg_name)
    subnet_id=$(aws autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$asg_name" \
        --query 'AutoScalingGroups[0].VPCZoneIdentifier' \
        --output text | tr ',' '\n' | head -1)

    info "Launching canary instance from launch template $launch_template_id..."
    local instance_id
    instance_id=$(aws ec2 run-instances \
        --launch-template "LaunchTemplateId=${launch_template_id},Version=\$Latest" \
        --subnet-id "$subnet_id" \
        --count 1 \
        --tag-specifications "ResourceType=instance,Tags=[{Key=${CANARY_TAG_KEY},Value=${CANARY_TAG_VALUE}},{Key=Name,Value=canary-test}]" \
        --query 'Instances[0].InstanceId' \
        --output text)

    info "Instance launched: $instance_id"
    info "Waiting for instance to be running..."
    aws ec2 wait instance-running --instance-ids "$instance_id"

    info "Registering instance in test target group..."
    aws elbv2 register-targets \
        --target-group-arn "$test_tg_arn" \
        --targets "Id=$instance_id"

    info "Waiting for target to become healthy (this may take several minutes)..."
    aws elbv2 wait target-in-service \
        --target-group-arn "$test_tg_arn" \
        --targets "Id=$instance_id"

    # Override nginx Host header so REDCap sees the production hostname
    if [[ -n "$prod_fqdn" ]]; then
        info "Applying nginx Host header override via SSM ($prod_fqdn)..."
        aws ssm send-command \
            --instance-ids "$instance_id" \
            --document-name "AWS-RunShellScript" \
            --parameters "commands=[
                \"sed -i '/include fastcgi_params;/a \\        fastcgi_param HTTP_HOST ${prod_fqdn};' /etc/nginx/conf.d/redcap.conf\",
                \"nginx -t && systemctl reload nginx\"
            ]" \
            --comment "Canary: override Host header" \
            --output text >/dev/null
        info "Host header override applied."
    fi

    echo ""
    info "Canary instance is live!"
    info "Instance ID: $instance_id"
    info "Test URL:    $test_url"
    echo ""
    info "Next steps:"
    info "  Verify at $test_url"
    info "  If good:  ./deploy.sh --promote"
    info "  If bad:   ./deploy.sh --abort"
}

# ── Canary: --promote ────────────────────────────────────────────────
do_promote() {
    info "Promoting canary to production..."

    local instance_id
    instance_id=$(find_canary_instance)
    if [[ -z "$instance_id" ]]; then
        error "No canary instance found. Nothing to promote."
        exit 1
    fi

    # Take pre-promote snapshot
    local cluster_id
    cluster_id=$(get_cluster_id)
    if [[ -n "$cluster_id" ]]; then
        create_snapshot "$cluster_id"
    fi

    # Start ASG instance refresh (rolling replacement with production instances)
    local asg_name
    asg_name=$(get_asg_name)
    info "Starting ASG instance refresh on $asg_name..."
    aws autoscaling start-instance-refresh \
        --auto-scaling-group-name "$asg_name" \
        --preferences '{"MinHealthyPercentage":100}' \
        >/dev/null

    # Clean up canary
    local test_tg_arn
    test_tg_arn=$(get_test_tg_arn)
    if [[ -n "$test_tg_arn" ]]; then
        info "Deregistering canary from test target group..."
        aws elbv2 deregister-targets \
            --target-group-arn "$test_tg_arn" \
            --targets "Id=$instance_id" 2>/dev/null || true
    fi

    info "Terminating canary instance $instance_id..."
    aws ec2 terminate-instances --instance-ids "$instance_id" >/dev/null

    echo ""
    info "Promote complete."
    info "ASG instance refresh is in progress — production instances will roll to \$Latest."
    info "Monitor with: aws autoscaling describe-instance-refreshes --auto-scaling-group-name $asg_name"
}

# ── Canary: --abort ──────────────────────────────────────────────────
do_abort() {
    info "Aborting canary deployment..."

    local instance_id
    instance_id=$(find_canary_instance)
    if [[ -z "$instance_id" ]]; then
        warn "No canary instance found. Nothing to abort."
        exit 0
    fi

    local test_tg_arn
    test_tg_arn=$(get_test_tg_arn)
    if [[ -n "$test_tg_arn" ]]; then
        info "Deregistering canary from test target group..."
        aws elbv2 deregister-targets \
            --target-group-arn "$test_tg_arn" \
            --targets "Id=$instance_id" 2>/dev/null || true
    fi

    info "Terminating canary instance $instance_id..."
    aws ec2 terminate-instances --instance-ids "$instance_id" >/dev/null

    echo ""
    info "Canary aborted. No production changes were made."
}

# ── Standard deploy (plan + snapshot + apply) ─────────────────────────
do_deploy() {
    local auto_approve="$1"
    local plan_only="$2"

    # Always run plan first
    info "Running terraform plan..."
    terraform plan -out=tfplan

    if $plan_only; then
        info "Plan-only mode. Exiting."
        exit 0
    fi

    # Check if there are actual changes
    if terraform show -json tfplan | python3 -c "
import json, sys
plan = json.load(sys.stdin)
changes = plan.get('resource_changes', [])
real = [c for c in changes if c.get('change',{}).get('actions',['no-op']) != ['no-op']]
sys.exit(0 if real else 1)
" 2>/dev/null; then
        info "Terraform plan has changes."
    else
        info "No changes detected. Nothing to do."
        rm -f tfplan
        exit 0
    fi

    # Take pre-deploy snapshot if cluster exists
    CLUSTER_ID=$(get_cluster_id)
    if [[ -n "$CLUSTER_ID" ]]; then
        create_snapshot "$CLUSTER_ID"
    else
        warn "No RDS cluster found in Terraform state — skipping snapshot."
        warn "This is expected on first deploy."
    fi

    # Prompt for confirmation (unless -auto)
    if [[ -z "$auto_approve" ]]; then
        echo ""
        warn "About to apply the above plan."
        read -rp "Continue? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            info "Aborted."
            rm -f tfplan
            exit 1
        fi
    fi

    # Apply
    info "Applying Terraform plan..."
    terraform apply $auto_approve tfplan
    rm -f tfplan

    info "Deploy complete."
}

# ── Main ─────────────────────────────────────────────────────────────
MODE="deploy"
AUTO_APPROVE=""
PLAN_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --test)                MODE="test" ;;
        --promote)             MODE="promote" ;;
        --abort)               MODE="abort" ;;
        -auto|--auto-approve)  AUTO_APPROVE="-auto-approve" ;;
        plan)                  PLAN_ONLY=true ;;
    esac
done

case "$MODE" in
    test)    do_test ;;
    promote) do_promote ;;
    abort)   do_abort ;;
    deploy)  do_deploy "$AUTO_APPROVE" "$PLAN_ONLY" ;;
esac
