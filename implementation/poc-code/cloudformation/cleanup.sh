#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# LDCF POC — cleanup.sh
# Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
#
# USAGE:
#   ./cleanup.sh              — PAUSE (default)
#                               Stops RDS, deletes DMS + NAT Gateway
#                               Saves ~$2.71/day. Remaining cost: ~$0.04/day
#
#   ./cleanup.sh --resume     — RESUME from paused state
#                               Recreates NAT Gateway, restarts RDS,
#                               re-enables S3 notifications, redeploys DMS
#
#   ./cleanup.sh --destroy-all — DELETE EVERYTHING permanently
#                               Requires typing DESTROY to confirm
#                               Cost after: $0/day
# ═══════════════════════════════════════════════════════════════
set -e

ENV="ldcf-poc"
REGION="us-east-1"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="${ENV}-deploy-${ACCOUNT}"
STATE_FILE=".pause-state"

GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'

log()   { echo -e "${GREEN}[LDCF]${NC} $1"; }
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}══ $1 ══${NC}\n"; }

MODE="${1:-pause}"

# ── Helper: get CloudFormation stack output value ────────────────
cf_output() {
    aws cloudformation describe-stacks \
        --stack-name "$1" --region "${REGION}" \
        --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" \
        --output text 2>/dev/null || echo ""
}

# ── Helper: get physical resource ID from CF stack ───────────────
cf_resource() {
    aws cloudformation describe-stack-resources \
        --stack-name "$1" --logical-resource-id "$2" \
        --query 'StackResources[0].PhysicalResourceId' \
        --output text 2>/dev/null || echo ""
}

# ── Helper: empty one S3 bucket (objects + versions + markers) ───
empty_s3_bucket() {
    local bucket=$1
    [ -z "${bucket}" ] || [ "${bucket}" = "None" ] && return
    aws s3 ls "s3://${bucket}" > /dev/null 2>&1 || return  # bucket doesn't exist

    info "Emptying S3 bucket: ${bucket}"

    # Delete all current objects
    aws s3 rm "s3://${bucket}" --recursive --quiet 2>/dev/null || true

    # Delete all versioned objects (if versioning enabled)
    local versions
    versions=$(aws s3api list-object-versions --bucket "${bucket}" \
        --query 'Versions[].{Key:Key,VersionId:VersionId}' \
        --output json 2>/dev/null || echo "[]")
    if [ "${versions}" != "[]" ] && [ "${versions}" != "null" ] && [ -n "${versions}" ]; then
        echo "${versions}" | python3 -c "
import json,sys,subprocess
objs=json.load(sys.stdin) or []
if objs:
    subprocess.run(['aws','s3api','delete-objects','--bucket','${bucket}',
        '--delete',json.dumps({'Objects':objs})],capture_output=True)
    print(f'  Deleted {len(objs)} versioned objects')
"
    fi

    # Delete all delete markers
    local markers
    markers=$(aws s3api list-object-versions --bucket "${bucket}" \
        --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' \
        --output json 2>/dev/null || echo "[]")
    if [ "${markers}" != "[]" ] && [ "${markers}" != "null" ] && [ -n "${markers}" ]; then
        echo "${markers}" | python3 -c "
import json,sys,subprocess
objs=json.load(sys.stdin) or []
if objs:
    subprocess.run(['aws','s3api','delete-objects','--bucket','${bucket}',
        '--delete',json.dumps({'Objects':objs})],capture_output=True)
    print(f'  Deleted {len(objs)} delete markers')
"
    fi

    info "Bucket ${bucket} emptied"
}

# ── Helper: empty all S3 buckets in a CF stack before delete ─────
empty_stack_buckets() {
    local stack=$1
    local buckets
    buckets=$(aws cloudformation describe-stack-resources \
        --stack-name "${stack}" --region "${REGION}" \
        --query 'StackResources[?ResourceType==`AWS::S3::Bucket`].PhysicalResourceId' \
        --output text 2>/dev/null || echo "")
    for bucket in ${buckets}; do
        empty_s3_bucket "${bucket}"
    done
}

# ── Helper: force-delete stuck DMS replication instance ──────────
force_delete_dms_instance() {
    local inst_arn
    inst_arn=$(aws dms describe-replication-instances \
        --region "${REGION}" \
        --query "ReplicationInstances[?contains(ReplicationInstanceIdentifier, '${ENV}')].ReplicationInstanceArn" \
        --output text 2>/dev/null || echo "")
    [ -z "${inst_arn}" ] || [ "${inst_arn}" = "None" ] && return

    local status
    status=$(aws dms describe-replication-instances \
        --region "${REGION}" \
        --filters "Name=replication-instance-arn,Values=${inst_arn}" \
        --query 'ReplicationInstances[0].ReplicationInstanceStatus' \
        --output text 2>/dev/null || echo "")

    if [ -n "${status}" ] && [ "${status}" != "None" ] && [ "${status}" != "deleted" ]; then
        warn "Force-deleting DMS replication instance (status: ${status})..."
        aws dms delete-replication-instance \
            --replication-instance-arn "${inst_arn}" \
            --region "${REGION}" > /dev/null 2>&1 || true

        info "Waiting for DMS replication instance to be deleted (~3 min)..."
        for i in $(seq 1 36); do
            status=$(aws dms describe-replication-instances \
                --filters "Name=replication-instance-arn,Values=${inst_arn}" \
                --query 'ReplicationInstances[0].ReplicationInstanceStatus' \
                --output text 2>/dev/null || echo "deleted")
            [ "${status}" = "deleted" ] || [ -z "${status}" ] && break
            info "DMS instance status: ${status} (${i}/36)..."
            sleep 5
        done
        log "DMS replication instance deleted"
    fi
}

# ── Helper: force-delete Lambda ENIs that block network stack ────
# Lambda creates service-managed ENIs for VPC access. When the Lambda
# stack is deleted first, these ENIs can linger for 15-20 minutes and
# block deletion of the Security Group and Subnet they are attached to,
# causing DELETE_FAILED on the network stack.
# This helper finds all such ENIs by description prefix and deletes them.
force_delete_lambda_enis() {
    # Resolve VPC ID from the network stack (may already be gone if called late)
    local vpc_id
    vpc_id=$(aws ec2 describe-vpcs \
        --filters "Name=tag:aws:cloudformation:stack-name,Values=${ENV}-network" \
        --query 'Vpcs[0].VpcId' \
        --output text --region "${REGION}" 2>/dev/null || echo "")

    # Fallback: find by Name tag
    if [ -z "${vpc_id}" ] || [ "${vpc_id}" = "None" ]; then
        vpc_id=$(aws ec2 describe-vpcs \
            --filters "Name=tag:Name,Values=${ENV}-vpc" \
            --query 'Vpcs[0].VpcId' \
            --output text --region "${REGION}" 2>/dev/null || echo "")
    fi

    if [ -z "${vpc_id}" ] || [ "${vpc_id}" = "None" ]; then
        info "No VPC found for ${ENV} — skipping Lambda ENI cleanup"
        return
    fi

    log "Cleaning up Lambda ENIs in VPC ${vpc_id}..."

    # Lambda ENIs have Description starting with "AWS Lambda VPC ENI-"
    # Also catch DMS and RDS interface endpoints with "ELB" / "RDSNetworkInterface"
    local eni_ids
    eni_ids=$(aws ec2 describe-network-interfaces \
        --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'NetworkInterfaces[?Status!=`in-use` || contains(Description,`Lambda`) || contains(Description,`AWS Lambda`)].NetworkInterfaceId' \
        --output text --region "${REGION}" 2>/dev/null || echo "")

    # Also fetch ALL ENIs in the VPC for the available ones
    local all_enis
    all_enis=$(aws ec2 describe-network-interfaces \
        --filters \
            "Name=vpc-id,Values=${vpc_id}" \
            "Name=status,Values=available" \
        --query 'NetworkInterfaces[*].NetworkInterfaceId' \
        --output text --region "${REGION}" 2>/dev/null || echo "")

    # Combine both sets (deduplicate via sort -u)
    local combined
    combined=$(echo -e "${eni_ids}\n${all_enis}" | tr '\t' '\n' | sort -u | grep -v '^$' || true)

    if [ -z "${combined}" ]; then
        info "No lingering ENIs found in VPC ${vpc_id}"
        return
    fi

    local count=0
    for ENI in ${combined}; do
        [ -z "${ENI}" ] && continue
        local description status
        description=$(aws ec2 describe-network-interfaces \
            --network-interface-ids "${ENI}" \
            --query 'NetworkInterfaces[0].Description' \
            --output text --region "${REGION}" 2>/dev/null || echo "")
        status=$(aws ec2 describe-network-interfaces \
            --network-interface-ids "${ENI}" \
            --query 'NetworkInterfaces[0].Status' \
            --output text --region "${REGION}" 2>/dev/null || echo "")

        info "  ENI ${ENI} (${status}): ${description}"

        # Detach if attached
        local attachment_id
        attachment_id=$(aws ec2 describe-network-interfaces \
            --network-interface-ids "${ENI}" \
            --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
            --output text --region "${REGION}" 2>/dev/null || echo "")
        if [ -n "${attachment_id}" ] && [ "${attachment_id}" != "None" ]; then
            aws ec2 detach-network-interface \
                --attachment-id "${attachment_id}" \
                --force --region "${REGION}" 2>/dev/null || true
            sleep 3
        fi

        # Delete the ENI
        if aws ec2 delete-network-interface \
            --network-interface-id "${ENI}" \
            --region "${REGION}" 2>/dev/null; then
            count=$((count + 1))
        else
            warn "  Could not delete ${ENI} yet — may still be detaching (will retry once)"
            sleep 10
            aws ec2 delete-network-interface \
                --network-interface-id "${ENI}" \
                --region "${REGION}" 2>/dev/null || \
            warn "  Skipping ${ENI} — AWS will clean it up automatically within 15 min"
        fi
    done

    log "Lambda ENI cleanup complete (${count} deleted)"
}

# ── Helper: delete a CF stack if it exists ───────────────────────
# Handles DELETE_FAILED by emptying S3 buckets and retrying once.
delete_stack() {
    local stack=$1

    # Check current stack state
    local state
    state=$(aws cloudformation describe-stacks --stack-name "${stack}" \
        --region "${REGION}" \
        --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")

    if [ "${state}" = "NOT_FOUND" ] || [ -z "${state}" ]; then
        info "Stack ${stack} not found — skipping"
        return
    fi

    # If already in DELETE_FAILED, empty buckets then retry
    if [ "${state}" = "DELETE_FAILED" ]; then
        warn "Stack ${stack} is in DELETE_FAILED — emptying S3 buckets and retrying..."
        empty_stack_buckets "${stack}"
    else
        # Pre-emptively empty S3 buckets before first delete attempt
        empty_stack_buckets "${stack}"
    fi

    log "Deleting stack: ${stack}..."
    aws cloudformation delete-stack --stack-name "${stack}" --region "${REGION}"

    # Wait, but don't exit on failure — handle DELETE_FAILED with one retry
    if ! aws cloudformation wait stack-delete-complete \
        --stack-name "${stack}" --region "${REGION}" 2>/dev/null; then

        state=$(aws cloudformation describe-stacks --stack-name "${stack}" \
            --region "${REGION}" \
            --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NOT_FOUND")

        if [ "${state}" = "DELETE_FAILED" ]; then
            warn "Stack ${stack} DELETE_FAILED — checking failed resources and retrying..."

            # Log which resources failed
            aws cloudformation describe-stack-events \
                --stack-name "${stack}" --region "${REGION}" \
                --query 'StackEvents[?ResourceStatus==`DELETE_FAILED`].[LogicalResourceId,ResourceStatusReason]' \
                --output table 2>/dev/null || true

            # Empty any buckets again (catches newly-created objects)
            empty_stack_buckets "${stack}"

            # Retry delete
            aws cloudformation delete-stack --stack-name "${stack}" --region "${REGION}"
            aws cloudformation wait stack-delete-complete \
                --stack-name "${stack}" --region "${REGION}" || {
                error "Stack ${stack} still DELETE_FAILED after retry. Manual cleanup required."
            }
        else
            error "Stack ${stack} deletion failed with status: ${state}"
        fi
    fi

    log "Stack ${stack} deleted"
}

# ── Helper: stop a DMS task and wait until stopped ───────────────
stop_dms_task() {
    local arn=$1 name=$2 status
    status=$(aws dms describe-replication-tasks \
        --filters "Name=replication-task-arn,Values=${arn}" \
        --query 'ReplicationTasks[0].Status' --output text 2>/dev/null || echo "")
    if [ "${status}" = "running" ]; then
        log "Stopping DMS task: ${name}"
        aws dms stop-replication-task \
            --replication-task-arn "${arn}" --region "${REGION}" > /dev/null
        for i in $(seq 1 18); do
            sleep 5
            status=$(aws dms describe-replication-tasks \
                --filters "Name=replication-task-arn,Values=${arn}" \
                --query 'ReplicationTasks[0].Status' --output text 2>/dev/null || echo "stopped")
            [ "${status}" = "stopped" ] && break
            info "Waiting for DMS task to stop... (${i}/18)"
        done
        log "DMS task ${name} stopped"
    else
        info "DMS task ${name} not running (status: ${status:-not found})"
    fi
}

# ════════════════════════════════════════════════════════════════
# PAUSE MODE  (default — no arguments)
# Deletes DMS replication instance ($1.63/day) and NAT Gateway ($1.08/day)
# Stops RDS instances (free tier — only storage charged ~$0.02/day each)
# Remaining cost: ~$0.04/day
# ════════════════════════════════════════════════════════════════
if [ "${MODE}" = "pause" ] || [ "${MODE}" = "--pause" ]; then
    step "LDCF POC — PAUSE MODE"
    log "Stopping costly resources. Saves ~\$2.71/day."

    # ── Collect resource IDs before any deletions ─────────────────
    TASK1_ARN=$(cf_output "${ENV}-dms" "FullLoadTaskArn")
    TASK2_ARN=$(cf_output "${ENV}-dms" "CDCTaskArn")
    NAT_ID=$(cf_resource "${ENV}-network" "NatGateway")
    RT_ID=$(cf_resource "${ENV}-network" "PrivateRouteTable")
    SUBNET_A=$(aws cloudformation list-exports --region "${REGION}" \
        --query "Exports[?Name=='${ENV}-subnet-a'].Value" --output text 2>/dev/null || echo "")
    LANDING_BUCKET=$(cf_output "${ENV}-pipeline" "LandingBucketName")
    LAMBDA1_ARN=$(cf_output "${ENV}-lambdas" "ClaimCheckLambdaArn")

    # Get EIP allocation ID while NAT still exists
    EIP_ALLOC=""
    if [ -n "${NAT_ID}" ] && [ "${NAT_ID}" != "None" ]; then
        EIP_ALLOC=$(aws ec2 describe-nat-gateways \
            --nat-gateway-ids "${NAT_ID}" \
            --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' \
            --output text 2>/dev/null || echo "")
    fi

    # ── Step 1: Stop DMS tasks ────────────────────────────────────
    [ -n "${TASK2_ARN}" ] && stop_dms_task "${TASK2_ARN}" "CDC"
    [ -n "${TASK1_ARN}" ] && stop_dms_task "${TASK1_ARN}" "FullLoad"
    sleep 5

    # ── Step 2: Delete DMS stack (removes ~$1.63/day) ─────────────
    log "Deleting DMS stack (removes replication instance)..."
    delete_stack "${ENV}-dms"

    # ── Step 3: Delete NAT Gateway + release EIP (~$1.08/day) ─────
    if [ -n "${NAT_ID}" ] && [ "${NAT_ID}" != "None" ] && [ "${NAT_ID}" != "" ]; then
        # Remove the 0.0.0.0/0 route from private route table first
        if [ -n "${RT_ID}" ] && [ "${RT_ID}" != "None" ]; then
            log "Removing NAT route from private route table..."
            aws ec2 delete-route --route-table-id "${RT_ID}" \
                --destination-cidr-block 0.0.0.0/0 2>/dev/null || true
        fi

        log "Deleting NAT Gateway ${NAT_ID}..."
        aws ec2 delete-nat-gateway --nat-gateway-id "${NAT_ID}" > /dev/null

        # Poll until deleted (no native waiter for deletion)
        log "Waiting for NAT Gateway to be deleted..."
        for i in $(seq 1 30); do
            STATUS=$(aws ec2 describe-nat-gateways \
                --nat-gateway-ids "${NAT_ID}" \
                --query 'NatGateways[0].State' --output text 2>/dev/null || echo "deleted")
            [ "${STATUS}" = "deleted" ] && break
            info "NAT Gateway state: ${STATUS} (${i}/30)..."
            sleep 10
        done
        log "NAT Gateway deleted"

        # Release the Elastic IP
        if [ -n "${EIP_ALLOC}" ] && [ "${EIP_ALLOC}" != "None" ]; then
            aws ec2 release-address --allocation-id "${EIP_ALLOC}" 2>/dev/null || true
            log "Elastic IP released"
        fi
    else
        info "NAT Gateway not found — already deleted"
    fi

    # ── Step 4: Stop RDS instances ────────────────────────────────
    log "Stopping RDS MySQL (ldcf-poc-mysql-legacy)..."
    aws rds stop-db-instance --db-instance-identifier "${ENV}-mysql-legacy" \
        --region "${REGION}" > /dev/null 2>&1 || info "MySQL already stopped or not found"

    log "Stopping RDS PostgreSQL (ldcf-poc-aurora-target)..."
    aws rds stop-db-instance --db-instance-identifier "${ENV}-aurora-target" \
        --region "${REGION}" > /dev/null 2>&1 || info "PostgreSQL already stopped or not found"

    # ── Step 5: Disable S3 event notification ─────────────────────
    if [ -n "${LANDING_BUCKET}" ]; then
        log "Disabling S3 event notification..."
        aws s3api put-bucket-notification-configuration \
            --bucket "${LANDING_BUCKET}" \
            --notification-configuration '{}' 2>/dev/null || true
    fi

    # ── Step 6: Save state for resume ────────────────────────────
    {
        echo "SUBNET_A=${SUBNET_A}"
        echo "RT_ID=${RT_ID}"
        echo "LANDING_BUCKET=${LANDING_BUCKET}"
        echo "LAMBDA1_ARN=${LAMBDA1_ARN}"
    } > "${STATE_FILE}"
    log "Pause state saved to ${STATE_FILE}"

    echo ""
    log "POC paused successfully."
    echo ""
    echo "  Deleted:  DMS Replication Instance   (~\$1.63/day saved)"
    echo "  Deleted:  NAT Gateway + Elastic IP   (~\$1.08/day saved)"
    echo "  Stopped:  RDS MySQL + PostgreSQL      (~\$0.00/day — free tier)"
    echo ""
    echo "  Remaining cost: ~\$0.04/day (RDS storage + Secrets Manager)"
    echo ""
    echo "  To resume:       ./cleanup.sh --resume"
    echo "  To destroy all:  ./cleanup.sh --destroy-all"

# ════════════════════════════════════════════════════════════════
# RESUME MODE  (--resume)
# Recreates NAT Gateway, restarts RDS, re-enables S3 notifications.
# Then re-run ./deploy.sh to redeploy the DMS stack.
# ════════════════════════════════════════════════════════════════
elif [ "${MODE}" = "--resume" ]; then
    step "LDCF POC — RESUME MODE"
    log "Restoring paused resources..."

    # Load saved state (or fall back to live stack reads)
    if [ -f "${STATE_FILE}" ]; then
        # shellcheck source=/dev/null
        source "${STATE_FILE}"
        log "Pause state loaded from ${STATE_FILE}"
    else
        warn "No ${STATE_FILE} found — reading from live stacks..."
        SUBNET_A=$(aws cloudformation list-exports --region "${REGION}" \
            --query "Exports[?Name=='${ENV}-subnet-a'].Value" --output text 2>/dev/null || echo "")
        RT_ID=$(cf_resource "${ENV}-network" "PrivateRouteTable")
        LANDING_BUCKET=$(cf_output "${ENV}-pipeline" "LandingBucketName")
        LAMBDA1_ARN=$(cf_output "${ENV}-lambdas" "ClaimCheckLambdaArn")
    fi

    if [ -z "${SUBNET_A}" ] || [ "${SUBNET_A}" = "None" ]; then
        error "Cannot find SubnetA. Is the network stack deployed? Run ./deploy.sh first."
    fi

    # ── Step 1: Allocate new Elastic IP ───────────────────────────
    log "Allocating new Elastic IP..."
    EIP_ALLOC=$(aws ec2 allocate-address --domain vpc \
        --region "${REGION}" --query AllocationId --output text)
    log "Elastic IP allocated: ${EIP_ALLOC}"

    # ── Step 2: Create NAT Gateway in SubnetA ─────────────────────
    log "Creating NAT Gateway in SubnetA (${SUBNET_A})..."
    NAT_ID=$(aws ec2 create-nat-gateway \
        --subnet-id "${SUBNET_A}" \
        --allocation-id "${EIP_ALLOC}" \
        --region "${REGION}" \
        --query 'NatGateway.NatGatewayId' --output text)
    log "NAT Gateway ${NAT_ID} created. Waiting for availability (~60s)..."
    aws ec2 wait nat-gateway-available \
        --nat-gateway-ids "${NAT_ID}" --region "${REGION}"
    log "NAT Gateway available"

    # ── Step 3: Restore private route table (SubnetB → NAT) ───────
    if [ -n "${RT_ID}" ] && [ "${RT_ID}" != "None" ]; then
        log "Restoring route: private subnet → NAT Gateway..."
        # Delete existing route if present (idempotent)
        aws ec2 delete-route --route-table-id "${RT_ID}" \
            --destination-cidr-block 0.0.0.0/0 2>/dev/null || true
        aws ec2 create-route \
            --route-table-id "${RT_ID}" \
            --destination-cidr-block 0.0.0.0/0 \
            --nat-gateway-id "${NAT_ID}" \
            --region "${REGION}" > /dev/null
        log "Route restored"
    fi

    # ── Step 4: Start RDS instances ───────────────────────────────
    log "Starting RDS MySQL..."
    aws rds start-db-instance --db-instance-identifier "${ENV}-mysql-legacy" \
        --region "${REGION}" > /dev/null 2>&1 || info "MySQL already running"

    log "Starting RDS PostgreSQL..."
    aws rds start-db-instance --db-instance-identifier "${ENV}-aurora-target" \
        --region "${REGION}" > /dev/null 2>&1 || info "PostgreSQL already running"

    log "Waiting for RDS MySQL to be available (~3 minutes)..."
    aws rds wait db-instance-available \
        --db-instance-identifier "${ENV}-mysql-legacy" --region "${REGION}"
    log "MySQL available"

    log "Waiting for RDS PostgreSQL to be available..."
    aws rds wait db-instance-available \
        --db-instance-identifier "${ENV}-aurora-target" --region "${REGION}"
    log "PostgreSQL available"

    # ── Step 5: Re-enable S3 event notification ───────────────────
    if [ -n "${LANDING_BUCKET}" ] && [ -n "${LAMBDA1_ARN}" ]; then
        log "Re-enabling S3 event notification (prefix=dms/sync/ suffix=.csv)..."
        aws s3api put-bucket-notification-configuration \
            --bucket "${LANDING_BUCKET}" \
            --notification-configuration "{
                \"LambdaFunctionConfigurations\": [{
                    \"LambdaFunctionArn\": \"${LAMBDA1_ARN}\",
                    \"Events\": [\"s3:ObjectCreated:*\"],
                    \"Filter\": {
                        \"Key\": {
                            \"FilterRules\": [
                                {\"Name\": \"prefix\", \"Value\": \"dms/sync/\"},
                                {\"Name\": \"suffix\", \"Value\": \".csv\"}
                            ]
                        }
                    }
                }]
            }"
        log "S3 notification re-enabled"
    fi

    # Clean up state file
    rm -f "${STATE_FILE}"

    echo ""
    log "Infrastructure restored."
    echo ""
    echo "  NAT Gateway:  ${NAT_ID}"
    echo "  RDS MySQL:    running"
    echo "  RDS PostgreSQL: running"
    echo ""
    warn "DMS stack was deleted during pause. Redeploy it now:"
    echo ""
    echo "    ./deploy.sh"
    echo ""
    echo "  deploy.sh will skip already-deployed stacks and redeploy DMS only."

# ════════════════════════════════════════════════════════════════
# DESTROY ALL  (--destroy-all)
# Permanently deletes every LDCF POC resource.
# Requires typing DESTROY to confirm.
# ════════════════════════════════════════════════════════════════
elif [ "${MODE}" = "--destroy-all" ]; then
    step "LDCF POC — DESTROY ALL"

    echo -e "${RED}${BOLD}"
    echo "  WARNING: This permanently deletes ALL LDCF POC resources."
    echo "  Databases, S3 data, Lambda functions, DMS tasks — everything."
    echo "  This CANNOT be undone."
    echo -e "${NC}"
    read -rp "Type DESTROY to confirm: " CONFIRM
    echo ""
    [ "${CONFIRM}" != "DESTROY" ] && error "Confirmation failed — type exactly: DESTROY"

    log "Starting full teardown of all LDCF POC resources..."

    # Collect before deletion
    TASK1_ARN=$(cf_output "${ENV}-dms" "FullLoadTaskArn")
    TASK2_ARN=$(cf_output "${ENV}-dms" "CDCTaskArn")

    # ── Step 1: Stop DMS tasks ────────────────────────────────────
    [ -n "${TASK2_ARN}" ] && stop_dms_task "${TASK2_ARN}" "CDC"
    [ -n "${TASK1_ARN}" ] && stop_dms_task "${TASK1_ARN}" "FullLoad"
    sleep 10

    # ── Step 2: Force-delete DMS replication instance if stuck ────
    # (prevents DELETE_FAILED on ldcf-poc-dms stack)
    force_delete_dms_instance

    # ── Step 3: Delete all stacks in reverse dependency order ─────
    # delete_stack() automatically:
    #   - empties S3 buckets before delete
    #   - retries once on DELETE_FAILED with fresh bucket empty
    for stack in \
        "${ENV}-dms" \
        "${ENV}-db-setup" \
        "${ENV}-lambdas" \
        "${ENV}-pipeline" \
        "${ENV}-metadata-seed" \
        "${ENV}-databases"; do
        delete_stack "${stack}"
    done

    # ── Step 3b: Clean up Lambda ENIs before network stack ────────
    # Lambda leaves behind service-managed ENIs in the VPC that can
    # linger for 15-20 min after the Lambda stack is deleted.
    # These block deletion of LambdaSG and SubnetB in the network stack.
    # Deleting them now prevents DELETE_FAILED on ldcf-poc-network.
    force_delete_lambda_enis

    # Brief pause to let AWS propagate ENI deletions
    sleep 5
    delete_stack "${ENV}-network"

    # ── Step 4: Delete the deploy bucket (not managed by CF) ──────
    empty_s3_bucket "${DEPLOY_BUCKET}"
    if aws s3 ls "s3://${DEPLOY_BUCKET}" > /dev/null 2>&1; then
        aws s3 rb "s3://${DEPLOY_BUCKET}" 2>/dev/null || true
        log "Deploy bucket ${DEPLOY_BUCKET} deleted"
    fi

    # Clean up local state file
    rm -f "${STATE_FILE}"

    echo ""
    echo -e "${BOLD}${GREEN}All LDCF POC resources deleted. Cost: \$0/day${NC}"
    echo ""
    echo "  To redeploy from scratch: ./deploy.sh"

else
    echo ""
    echo "Usage: $0 [--pause | --resume | --destroy-all]"
    echo ""
    echo "  (no flag)       PAUSE        Stop RDS, delete DMS + NAT Gateway"
    echo "                               Saves ~\$2.71/day  |  Remaining: ~\$0.04/day"
    echo ""
    echo "  --resume        RESUME       Recreate NAT, restart RDS, redeploy DMS"
    echo ""
    echo "  --destroy-all   DESTROY ALL  Delete everything permanently"
    echo "                               Requires typing DESTROY to confirm"
    echo ""
    exit 1
fi
