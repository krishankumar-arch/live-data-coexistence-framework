#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# LDCF POC — deploy.sh
# Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
#
# Deploys all five CloudFormation stacks in order.
# Pauses at key manual steps (SQL setup, DMS start, keyring load).
#
# USAGE: ./deploy.sh
# PREREQUISITE: aws configure must be complete (aws sts get-caller-identity)
# ═══════════════════════════════════════════════════════════════
set -e

# ── Config ───────────────────────────────────────────────────────
ENV="ldcf-poc"
REGION="us-east-1"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="${ENV}-deploy-${ACCOUNT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAMBDA_DIR="${SCRIPT_DIR}/../lambda"

# ── Colors ───────────────────────────────────────────────────────
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'

log()   { echo -e "${GREEN}[LDCF]${NC} $1"; }
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WAIT]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}══ $1 ══${NC}\n"; }

# ── Prompt for passwords ─────────────────────────────────────────
step "LDCF POC Deployment"
log "Account: ${ACCOUNT} | Region: ${REGION}"
echo ""
read -s -p "Enter DB password (min 8 chars, used for both MySQL and Aurora): " DB_PASSWORD
echo ""
read -p "Enter alert email for SNS notifications: " ALERT_EMAIL
echo ""

# ── Step 1: Create Lambda deployment S3 bucket ──────────────────
step "Step 1/8 — Create Lambda deployment bucket"
if aws s3 ls "s3://${DEPLOY_BUCKET}" 2>/dev/null; then
    log "Bucket ${DEPLOY_BUCKET} already exists"
else
    aws s3 mb "s3://${DEPLOY_BUCKET}" --region ${REGION}
    log "Created bucket: ${DEPLOY_BUCKET}"
fi

# ── Step 2: Package and upload Lambda functions ──────────────────
step "Step 2/8 — Package and upload Lambda functions"

package_lambda() {
    local name=$1
    local dir="${LAMBDA_DIR}/${name}"
    local zipfile="/tmp/${name}.zip"

    log "Packaging ${name}..."
    cd "${dir}"

    # Install dependencies if requirements.txt exists
    if [ -f requirements.txt ]; then
        pip install -r requirements.txt -t ./package --quiet --break-system-packages 2>/dev/null || \
        pip install -r requirements.txt -t ./package --quiet 2>/dev/null || true
        cd package && zip -r "${zipfile}" . -x "*.pyc" > /dev/null && cd ..
        zip -g "${zipfile}" *.py > /dev/null
        rm -rf package
    else
        zip "${zipfile}" *.py > /dev/null
    fi

    aws s3 cp "${zipfile}" "s3://${DEPLOY_BUCKET}/lambda/${name}.zip" --quiet
    log "Uploaded ${name}.zip"
    cd "${SCRIPT_DIR}"
}

package_lambda "01_claim_check"
package_lambda "02_upstream_loader"
package_lambda "03_metadata_service"
package_lambda "04_dlq_requeue"

# ── Step 3: Deploy network stack ─────────────────────────────────
step "Step 3/8 — Deploy network stack"
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/01_network.yaml" \
    --stack-name "${ENV}-network" \
    --parameter-overrides EnvironmentName=${ENV} \
    --capabilities CAPABILITY_IAM \
    --region ${REGION}
log "Network stack deployed"

# ── Step 4: Deploy databases stack ───────────────────────────────
step "Step 4/8 — Deploy databases stack (takes ~10 minutes)"
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/02_databases.yaml" \
    --stack-name "${ENV}-databases" \
    --parameter-overrides \
        EnvironmentName=${ENV} \
        DBPassword=${DB_PASSWORD} \
    --capabilities CAPABILITY_IAM \
    --region ${REGION}
log "Database stack deployed"

# Get endpoints
MYSQL_HOST=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-databases" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`MySQLEndpoint`].OutputValue' \
    --output text)
AURORA_HOST=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-databases" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`AuroraEndpoint`].OutputValue' \
    --output text)
MYSQL_SECRET=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-databases" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`MySQLSecretArn`].OutputValue' \
    --output text)
AURORA_SECRET=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-databases" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`AuroraSecretArn`].OutputValue' \
    --output text)

echo ""
echo -e "${BOLD}Database Endpoints:${NC}"
echo "  MySQL:  ${MYSQL_HOST}"
echo "  Aurora: ${AURORA_HOST}"
echo ""

# ── PAUSE: Run SQL setup scripts ─────────────────────────────────
warn "═══════════════════════════════════════════════════════════"
warn "MANUAL STEP REQUIRED — Run SQL setup scripts"
warn "═══════════════════════════════════════════════════════════"
echo ""
echo "Run these commands in a separate terminal:"
echo ""
echo -e "${YELLOW}  # MySQL legacy schema${NC}"
echo "  mysql -h ${MYSQL_HOST} -u ldcfadmin -p < ../setup/01_mysql_legacy_schema.sql"
echo ""
echo -e "${YELLOW}  # Aurora target schema${NC}"
echo "  psql -h ${AURORA_HOST} -U ldcfadmin -d ldcfdb -f ../setup/02_aurora_target_schema.sql"
echo ""
echo -e "${YELLOW}  # Metadata seed data (update placeholders first)${NC}"
echo "  # Edit 03_metadata_seed.sql — replace MYSQL_ENDPOINT_PLACEHOLDER with: ${MYSQL_HOST}"
echo "  # Edit 03_metadata_seed.sql — replace AURORA_ENDPOINT_PLACEHOLDER with: ${AURORA_HOST}"
echo "  psql -h ${AURORA_HOST} -U ldcfadmin -d ldcfdb -f ../setup/03_metadata_seed.sql"
echo ""
read -p "Press Enter when SQL setup is complete..."

# ── Step 5: Deploy pipeline stack ────────────────────────────────
step "Step 5/8 — Deploy pipeline stack"
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/03_pipeline.yaml" \
    --stack-name "${ENV}-pipeline" \
    --parameter-overrides \
        EnvironmentName=${ENV} \
        AlertEmail=${ALERT_EMAIL} \
    --capabilities CAPABILITY_IAM \
    --region ${REGION}
log "Pipeline stack deployed"

LANDING_BUCKET=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-pipeline" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`LandingBucketName`].OutputValue' \
    --output text)

# ── Step 6: Deploy Lambdas stack ─────────────────────────────────
step "Step 6/8 — Deploy Lambda functions stack"
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/04_lambdas.yaml" \
    --stack-name "${ENV}-lambdas" \
    --parameter-overrides \
        EnvironmentName=${ENV} \
        LambdaDeployBucket=${DEPLOY_BUCKET} \
        DBHost=${AURORA_HOST} \
        AuroraSecretArn=${AURORA_SECRET} \
    --capabilities CAPABILITY_NAMED_IAM \
    --region ${REGION}
log "Lambda stack deployed"

# Wire S3 → Lambda 1 notification
LAMBDA1_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-lambdas" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`ClaimCheckLambdaArn`].OutputValue' \
    --output text)

aws s3api put-bucket-notification-configuration \
    --bucket "${LANDING_BUCKET}" \
    --notification-configuration "{
        \"LambdaFunctionConfigurations\": [{
            \"LambdaFunctionArn\": \"${LAMBDA1_ARN}\",
            \"Events\": [\"s3:ObjectCreated:*\"],
            \"Filter\": {\"Key\": {\"FilterRules\": [{\"Name\": \"suffix\", \"Value\": \".csv\"}]}}
        }]
    }"
log "S3 → Lambda notification configured"

# ── Step 7: Deploy DMS stack ──────────────────────────────────────
step "Step 7/8 — Deploy DMS stack (takes ~10 minutes)"
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/05_dms.yaml" \
    --stack-name "${ENV}-dms" \
    --parameter-overrides \
        EnvironmentName=${ENV} \
        MySQLEndpoint=${MYSQL_HOST} \
        AuroraEndpoint=${AURORA_HOST} \
        MySQLPassword=${DB_PASSWORD} \
        AuroraPassword=${DB_PASSWORD} \
        LandingBucketName=${LANDING_BUCKET} \
    --capabilities CAPABILITY_NAMED_IAM \
    --region ${REGION}
log "DMS stack deployed"

TASK1_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-dms" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`FullLoadTaskArn`].OutputValue' \
    --output text)
TASK2_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-dms" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`CDCTaskArn`].OutputValue' \
    --output text)

# ── PAUSE: Start DMS Task 1 ───────────────────────────────────────
warn "═══════════════════════════════════════════════════════════"
warn "MANUAL STEP — Start DMS Task 1 (Full Load)"
warn "═══════════════════════════════════════════════════════════"
echo ""
echo "Run in a separate terminal:"
echo ""
echo -e "${YELLOW}  aws dms start-replication-task \\"
echo "    --replication-task-arn ${TASK1_ARN} \\"
echo -e "    --start-replication-task-type start-replication${NC}"
echo ""
echo "Then monitor status:"
echo "  aws dms describe-replication-tasks \\"
echo "    --filters Name=replication-task-arn,Values=${TASK1_ARN} \\"
echo "    --query 'ReplicationTasks[0].Status' --output text"
echo ""
echo "Wait until status = 'stopped' (full load complete)"
read -p "Press Enter when DMS Task 1 shows status 'stopped'..."

# ── PAUSE: Run keyring load ───────────────────────────────────────
warn "═══════════════════════════════════════════════════════════"
warn "MANUAL STEP — Run keyring one-time load script"
warn "═══════════════════════════════════════════════════════════"
echo ""
echo "Run in a separate terminal:"
echo ""
echo -e "${YELLOW}  psql -h ${AURORA_HOST} -U ldcfadmin -d ldcfdb \\"
echo -e "    -f ../setup/04_keyring_oneshot_load.sql${NC}"
echo ""
echo "Verify claim_keyring and policy_keyring row counts match claim and policy."
read -p "Press Enter when keyring load is complete..."

# ── Step 8: Start DMS Task 2 (CDC) ───────────────────────────────
step "Step 8/8 — Start DMS Task 2 (CDC)"
warn "═══════════════════════════════════════════════════════════"
warn "MANUAL STEP — Start DMS Task 2 (CDC)"
warn "═══════════════════════════════════════════════════════════"
echo ""
echo "Run in a separate terminal:"
echo ""
echo -e "${YELLOW}  aws dms start-replication-task \\"
echo "    --replication-task-arn ${TASK2_ARN} \\"
echo -e "    --start-replication-task-type start-replication${NC}"
echo ""
read -p "Press Enter when DMS Task 2 is running..."

# ── Final summary ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════"
echo "  LDCF POC DEPLOYED SUCCESSFULLY"
echo -e "═══════════════════════════════════════════════════════════${NC}"
echo ""
echo "Resource Summary:"
echo "  MySQL endpoint:   ${MYSQL_HOST}"
echo "  Aurora endpoint:  ${AURORA_HOST}"
echo "  Landing bucket:   ${LANDING_BUCKET}"
echo "  Deploy bucket:    ${DEPLOY_BUCKET}"
echo "  DMS Task 1 ARN:   ${TASK1_ARN}"
echo "  DMS Task 2 ARN:   ${TASK2_ARN}"
echo ""
echo "Operations:"
echo "  Pause:   ./cleanup.sh"
echo "  Resume:  ./cleanup.sh --resume"
echo "  Destroy: ./cleanup.sh --destroy-all"
echo ""
log "LDCF POC is live. CDC replication is running."
