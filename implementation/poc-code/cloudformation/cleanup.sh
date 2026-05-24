#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# LDCF POC — cleanup.sh
# Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
#
# USAGE:
#   ./cleanup.sh              — PAUSE  (stop services, keep infra, ~$0.10/day)
#   ./cleanup.sh --resume     — RESUME (restart everything from last checkpoint)
#   ./cleanup.sh --destroy-all — DESTROY (delete everything — requires DESTROY confirmation)
# ═══════════════════════════════════════════════════════════════
set -e

ENV="ldcf-poc"
REGION="us-east-1"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="${ENV}-deploy-${ACCOUNT}"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'

log()   { echo -e "${GREEN}[LDCF]${NC} $1"; }
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step()  { echo -e "\n${BOLD}${BLUE}══ $1 ══${NC}\n"; }

MODE="${1:-pause}"

# ── Helper: get CloudFormation output ────────────────────────────
cf_output() {
    aws cloudformation describe-stacks \
        --stack-name "$1" --region ${REGION} \
        --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
        --output text 2>/dev/null || echo ""
}

# ── Helper: stop DMS task safely ─────────────────────────────────
stop_dms_task() {
    local arn=$1
    local name=$2
    local status
    status=$(aws dms describe-replication-tasks \
        --filters "Name=replication-task-arn,Values=${arn}" \
        --query 'ReplicationTasks[0].Status' --output text 2>/dev/null || echo "")

    if [ "${status}" = "running" ]; then
        log "Stopping DMS task: ${name}"
        aws dms stop-replication-task --replication-task-arn "${arn}" --region ${REGION} > /dev/null
        log "DMS task ${name} stop initiated"
    else
        info "DMS task ${name} already stopped (status: ${status})"
    fi
}

# ════════════════════════════════════════════════════════════════
# PAUSE MODE (default)
# ════════════════════════════════════════════════════════════════
if [ "${MODE}" = "pause" ] || [ "${MODE}" = "--pause" ]; then
    step "LDCF POC — PAUSE MODE"
    log "Pausing all services. Infrastructure preserved. Cost: ~\$0.10/day"

    # Get resource identifiers
    TASK1_ARN=$(cf_output "${ENV}-dms" "FullLoadTaskArn")
    TASK2_ARN=$(cf_output "${ENV}-dms" "CDCTaskArn")
    LANDING_BUCKET=$(cf_output "${ENV}-pipeline" "LandingBucketName")
    MYSQL_ID="${ENV}-mysql-legacy"
    AURORA_ID="${ENV}-aurora-target"
    LAMBDA1_ARN=$(cf_output "${ENV}-lambdas" "ClaimCheckLambdaArn")

    # Stop DMS tasks
    [ -n "${TASK2_ARN}" ] && stop_dms_task "${TASK2_ARN}" "CDC"
    [ -n "${TASK1_ARN}" ] && stop_dms_task "${TASK1_ARN}" "FullLoad"

    # Stop RDS MySQL (free when stopped; auto-restarts after 7 days)
    log "Stopping RDS MySQL..."
    aws rds stop-db-instance --db-instance-identifier "${MYSQL_ID}" \
        --region ${REGION} > /dev/null 2>&1 || info "MySQL already stopped"

    # Disable S3 event notification (stops Lambda 1 from triggering)
    if [ -n "${LANDING_BUCKET}" ]; then
        log "Disabling S3 event notification..."
        aws s3api put-bucket-notification-configuration \
            --bucket "${LANDING_BUCKET}" \
            --notification-configuration '{}' 2>/dev/null || true
    fi

    # Aurora Serverless v2 scales to minimum ACU automatically when idle
    # No manual action needed — scales to ~0.5 ACU near-zero cost
    info "Aurora Serverless v2 will auto-scale to minimum ACU (near-zero cost)"

    echo ""
    log "POC paused successfully."
    echo "  Estimated cost while paused: ~\$0.10/day"
    echo "  To resume: ./cleanup.sh --resume"
    echo "  To destroy: ./cleanup.sh --destroy-all"

# ════════════════════════════════════════════════════════════════
# RESUME MODE
# ════════════════════════════════════════════════════════════════
elif [ "${MODE}" = "--resume" ]; then
    step "LDCF POC — RESUME MODE"
    log "Resuming all services..."

    TASK2_ARN=$(cf_output "${ENV}-dms" "CDCTaskArn")
    LANDING_BUCKET=$(cf_output "${ENV}-pipeline" "LandingBucketName")
    LAMBDA1_ARN=$(cf_output "${ENV}-lambdas" "ClaimCheckLambdaArn")
    MYSQL_ID="${ENV}-mysql-legacy"

    # Start RDS MySQL
    log "Starting RDS MySQL..."
    aws rds start-db-instance --db-instance-identifier "${MYSQL_ID}" \
        --region ${REGION} > /dev/null 2>&1 || info "MySQL already running"

    # Wait for MySQL to be available
    log "Waiting for MySQL to be available (~3 minutes)..."
    aws rds wait db-instance-available \
        --db-instance-identifier "${MYSQL_ID}" \
        --region ${REGION}
    log "MySQL available"

    # Re-enable S3 event notification
    if [ -n "${LANDING_BUCKET}" ] && [ -n "${LAMBDA1_ARN}" ]; then
        log "Re-enabling S3 event notification..."
        aws s3api put-bucket-notification-configuration \
            --bucket "${LANDING_BUCKET}" \
            --notification-configuration "{
                \"LambdaFunctionConfigurations\": [{
                    \"LambdaFunctionArn\": \"${LAMBDA1_ARN}\",
                    \"Events\": [\"s3:ObjectCreated:*\"],
                    \"Filter\": {\"Key\": {\"FilterRules\": [{\"Name\": \"suffix\", \"Value\": \".csv\"}]}}
                }]
            }"
        log "S3 notification re-enabled"
    fi

    # Resume DMS CDC task from last checkpoint
    if [ -n "${TASK2_ARN}" ]; then
        log "Resuming DMS CDC task from last checkpoint..."
        aws dms start-replication-task \
            --replication-task-arn "${TASK2_ARN}" \
            --start-replication-task-type resume-processing \
            --region ${REGION} > /dev/null
        log "DMS CDC task resuming"
    fi

    echo ""
    log "POC resumed. CDC replication is running from last checkpoint."

# ════════════════════════════════════════════════════════════════
# DESTROY MODE
# ════════════════════════════════════════════════════════════════
elif [ "${MODE}" = "--destroy-all" ]; then
    step "LDCF POC — DESTROY MODE"

    echo -e "${RED}${BOLD}"
    echo "  ⚠️  WARNING: This will permanently delete ALL LDCF POC resources."
    echo "  This includes all databases, S3 data, Lambda functions, and DMS tasks."
    echo "  This action CANNOT be undone."
    echo -e "${NC}"
    read -p "Type DESTROY to confirm: " CONFIRM
    echo ""

    if [ "${CONFIRM}" != "DESTROY" ]; then
        error "Confirmation failed. Type exactly: DESTROY"
    fi

    log "Starting destruction of all LDCF POC resources..."

    # Get resource names before stacks are deleted
    LANDING_BUCKET=$(cf_output "${ENV}-pipeline" "LandingBucketName")
    TASK1_ARN=$(cf_output "${ENV}-dms" "FullLoadTaskArn")
    TASK2_ARN=$(cf_output "${ENV}-dms" "CDCTaskArn")

    # Stop DMS tasks first
    [ -n "${TASK2_ARN}" ] && stop_dms_task "${TASK2_ARN}" "CDC"
    [ -n "${TASK1_ARN}" ] && stop_dms_task "${TASK1_ARN}" "FullLoad"

    # Wait a moment for DMS tasks to stop
    sleep 10

    # Delete stacks in reverse dependency order
    for stack in "${ENV}-dms" "${ENV}-lambdas" "${ENV}-pipeline" "${ENV}-databases" "${ENV}-network"; do
        if aws cloudformation describe-stacks --stack-name "${stack}" \
            --region ${REGION} > /dev/null 2>&1; then
            log "Deleting stack: ${stack}"
            aws cloudformation delete-stack --stack-name "${stack}" --region ${REGION}
            log "Waiting for ${stack} deletion..."
            aws cloudformation wait stack-delete-complete \
                --stack-name "${stack}" --region ${REGION}
            log "Stack ${stack} deleted"
        else
            info "Stack ${stack} not found — skipping"
        fi
    done

    # Empty and delete S3 buckets
    if [ -n "${LANDING_BUCKET}" ]; then
        log "Emptying landing bucket: ${LANDING_BUCKET}"
        aws s3 rm "s3://${LANDING_BUCKET}" --recursive --quiet 2>/dev/null || true
        aws s3 rb "s3://${LANDING_BUCKET}" 2>/dev/null || true
        log "Landing bucket deleted"
    fi

    log "Emptying deploy bucket: ${DEPLOY_BUCKET}"
    aws s3 rm "s3://${DEPLOY_BUCKET}" --recursive --quiet 2>/dev/null || true
    aws s3 rb "s3://${DEPLOY_BUCKET}" 2>/dev/null || true

    echo ""
    echo -e "${BOLD}${GREEN}All LDCF POC resources have been deleted.${NC}"
    echo "  Cost: \$0/day"
    echo "  To redeploy: ./deploy.sh"

else
    echo "Usage: $0 [--pause | --resume | --destroy-all]"
    echo "  (no flag)       Pause — stop services, keep infrastructure"
    echo "  --resume        Resume from paused state"
    echo "  --destroy-all   Delete everything permanently"
    exit 1
fi
