#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# LDCF POC — deploy.sh
# Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
#
# USAGE: ./deploy.sh
# PREREQUISITE: aws configure complete + aws sts get-caller-identity works
#
# WHAT THIS SCRIPT DOES (9 steps):
#   Step 1 — Create Lambda deploy S3 bucket
#   Step 2 — Package + upload all 5 Lambda functions
#   Step 3 — Deploy Network stack
#   Step 4 — Deploy Database stack (~10-15 min)
#   Step 5 — Upload SQL scripts + Deploy DB Setup stack (runs SQL automatically)
#   Step 6 — Deploy Pipeline stack
#   Step 7 — Deploy Lambda stack + wire S3 notification
#   Step 8 — Deploy DMS stack (~10-15 min for replication instance)
#   Step 9 — Start DMS tasks (manual steps) + summary
#
# NO MANUAL SQL STEPS — the db_setup Lambda runs all 4 .sql scripts.
# Use DBeaver to verify / browse after deployment.
# ═══════════════════════════════════════════════════════════════
set -e

# ── Config ───────────────────────────────────────────────────────
ENV="ldcf-poc"
REGION="us-east-1"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
DEPLOY_BUCKET="${ENV}-deploy-${ACCOUNT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAMBDA_DIR="${SCRIPT_DIR}/../lambda"
SETUP_DIR="${SCRIPT_DIR}/../setup"

# ── Colors ───────────────────────────────────────────────────────
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'
log()   { echo -e "${GREEN}[LDCF]${NC} $1"; }
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WAIT]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}══ $1 ══${NC}\n"; }

# ── Pre-flight checks ─────────────────────────────────────────────
step "Pre-flight Checks"
command -v aws     >/dev/null || error "AWS CLI not found. Install from https://aws.amazon.com/cli/"
command -v python3 >/dev/null || error "Python3 not found."
command -v zip     >/dev/null || error "zip not found. Install: brew install zip (mac) or apt install zip (linux)"
command -v pip3    >/dev/null || error "pip3 not found."
log "All tools found"
log "Account: ${ACCOUNT} | Region: ${REGION}"

# ── Collect inputs ────────────────────────────────────────────────
step "Configuration"
echo ""

# Load credentials from deploy.env if present, otherwise prompt interactively.
# deploy.env is in .gitignore -- safe to store passwords there.
# Template: copy deploy.env.example -> deploy.env and fill in values.
ENV_FILE="${SCRIPT_DIR}/deploy.env"
if [ -f "${ENV_FILE}" ]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
    log "Loaded credentials from deploy.env"
    echo ""
    # Validate all required vars are set and non-empty
    if [ -z "${DB_PASSWORD:-}" ] || [ "${DB_PASSWORD}" = "ChangeMe#2024!" ]; then
        error "deploy.env found but DB_PASSWORD is not set or still has the example value. Edit deploy.env first."
    fi
    if [ -z "${DMS_PASSWORD:-}" ] || [ "${DMS_PASSWORD}" = "DmsRepl#2024!" ]; then
        error "deploy.env found but DMS_PASSWORD is not set or still has the example value. Edit deploy.env first."
    fi
    if [ -z "${ALERT_EMAIL:-}" ] || [ "${ALERT_EMAIL}" = "ops@example.com" ]; then
        error "deploy.env found but ALERT_EMAIL is not set or still has the example value. Edit deploy.env first."
    fi
    if [ "${DB_PASSWORD}" = "${DMS_PASSWORD}" ]; then
        error "DB_PASSWORD and DMS_PASSWORD must be different."
    fi
    info "DB_PASSWORD:  *** (loaded)"
    info "DMS_PASSWORD: *** (loaded)"
    info "ALERT_EMAIL:  ${ALERT_EMAIL}"
    echo ""
else
    # No deploy.env — fall back to interactive prompts
    warn "deploy.env not found. Prompting interactively."
    warn "Tip: copy deploy.env.example -> deploy.env to skip prompts next time."
    echo ""

    read -s -p "DB admin password (min 8 chars, letters+numbers+special): " DB_PASSWORD
    echo ""
    if [ ${#DB_PASSWORD} -lt 8 ]; then
        error "Password must be at least 8 characters"
    fi

    read -s -p "DMS replication user password (different from admin): " DMS_PASSWORD
    echo ""
    if [ ${#DMS_PASSWORD} -lt 8 ]; then
        error "DMS password must be at least 8 characters"
    fi
    if [ "${DB_PASSWORD}" = "${DMS_PASSWORD}" ]; then
        error "DB_PASSWORD and DMS_PASSWORD must be different."
    fi

    read -p "Alert email for SNS notifications: " ALERT_EMAIL
    echo ""
fi
log "Configuration ready"

# ── Step 1: Create Lambda deployment S3 bucket ───────────────────
step "Step 1/9 — Lambda deployment bucket"
if aws s3 ls "s3://${DEPLOY_BUCKET}" 2>/dev/null; then
    log "Bucket ${DEPLOY_BUCKET} already exists — skipping"
else
    aws s3 mb "s3://${DEPLOY_BUCKET}" --region ${REGION}
    log "Created: s3://${DEPLOY_BUCKET}"
fi

# ── Step 2: Package and upload Lambda functions ───────────────────
step "Step 2/9 — Package Lambda functions"

package_lambda() {
    local name=$1
    local src_dir="${LAMBDA_DIR}/${name}"
    local build_dir="/tmp/ldcf-lambda-build/${name}"
    local zipfile="/tmp/ldcf-lambda-build/${name}.zip"

    log "Packaging ${name}..."

    rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    # Copy source files
    cp "${src_dir}"/*.py "${build_dir}/" 2>/dev/null || true

    # Install dependencies
    if [ -f "${src_dir}/requirements.txt" ]; then
        pip3 install \
            -r "${src_dir}/requirements.txt" \
            -t "${build_dir}" \
            --quiet \
            --no-cache-dir \
            --platform manylinux2014_x86_64 \
            --implementation cp \
            --python-version 3.11 \
            --only-binary=:all: \
            2>/dev/null || \
        pip3 install \
            -r "${src_dir}/requirements.txt" \
            -t "${build_dir}" \
            --quiet \
            --no-cache-dir \
            2>/dev/null || true
    fi

    cd "${build_dir}"
    zip -r "${zipfile}" . \
        --exclude "*.pyc" \
        --exclude "__pycache__/*" \
        --exclude "*.dist-info/*" \
        --exclude "*.egg-info/*" \
        > /dev/null

    aws s3 cp "${zipfile}" \
        "s3://${DEPLOY_BUCKET}/lambda/${name}.zip" \
        --quiet

    local size=$(du -sh "${zipfile}" | cut -f1)
    log "Uploaded ${name}.zip (${size})"
    cd "${SCRIPT_DIR}"
}

mkdir -p /tmp/ldcf-lambda-build
package_lambda "01_claim_check"
package_lambda "02_upstream_loader"
package_lambda "03_metadata_service"
package_lambda "04_dlq_requeue"
package_lambda "05_db_setup"           # DB setup custom resource
log "All Lambda packages uploaded"

# ── Step 3: Network stack ─────────────────────────────────────────
step "Step 3/9 — Network stack"
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/01_network.yaml" \
    --stack-name "${ENV}-network" \
    --parameter-overrides EnvironmentName=${ENV} \
    --capabilities CAPABILITY_IAM \
    --region ${REGION} \
    --no-fail-on-empty-changeset
log "Network stack ready"

# ── Step 4: Database stack ────────────────────────────────────────
step "Step 4/9 — Database stack (~10-15 minutes)"
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/02_databases.yaml" \
    --stack-name "${ENV}-databases" \
    --parameter-overrides \
        EnvironmentName=${ENV} \
        DBPassword=${DB_PASSWORD} \
    --capabilities CAPABILITY_IAM \
    --region ${REGION} \
    --no-fail-on-empty-changeset
log "Database stack ready"

# Get endpoints
MYSQL_HOST=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-databases" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`MySQLEndpoint`].OutputValue' \
    --output text)
AURORA_HOST=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-databases" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`AuroraEndpoint`].OutputValue' \
    --output text)
MYSQL_SECRET_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-databases" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`MySQLSecretArn`].OutputValue' \
    --output text)
AURORA_SECRET_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-databases" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`AuroraSecretArn`].OutputValue' \
    --output text)

echo ""
echo -e "${BOLD}Endpoints:${NC}"
echo "  MySQL:  ${MYSQL_HOST}"
echo "  Aurora: ${AURORA_HOST}"
echo ""

# Store DMS user credentials in Secrets Manager
log "Storing DMS user credentials in Secrets Manager..."
aws secretsmanager create-secret \
    --name "${ENV}-dms-mysql-secret" \
    --description "LDCF POC DMS replication user credentials" \
    --secret-string "{\"username\":\"ldcf_dms_user\",\"password\":\"${DMS_PASSWORD}\"}" \
    --region ${REGION} 2>/dev/null || \
aws secretsmanager update-secret \
    --secret-id "${ENV}-dms-mysql-secret" \
    --secret-string "{\"username\":\"ldcf_dms_user\",\"password\":\"${DMS_PASSWORD}\"}" \
    --region ${REGION}
log "DMS credentials stored"

# Retrieve DMS secret ARN for CloudFormation parameter
DMS_SECRET_ARN=$(aws secretsmanager describe-secret \
    --secret-id "${ENV}-dms-mysql-secret" \
    --region ${REGION} \
    --query 'ARN' --output text)
log "DMS secret ARN: ${DMS_SECRET_ARN}"

# ── Step 5: DB Setup stack (automated SQL execution) ─────────────
step "Step 5/9 — DB Setup stack (runs all SQL scripts automatically, ~3 min)"

# Patch 03_metadata_seed.sql with actual endpoints BEFORE uploading to S3
log "Patching 03_metadata_seed.sql with actual endpoints..."
cp "${SETUP_DIR}/03_metadata_seed.sql" "${SETUP_DIR}/03_metadata_seed.sql.bak" 2>/dev/null || true
sed -i.bak \
    -e "s|MYSQL_HOST_PLACEHOLDER|${MYSQL_HOST}|g" \
    -e "s|AURORA_HOST_PLACEHOLDER|${AURORA_HOST}|g" \
    -e "s|MYSQL_SECRET_ARN_PLACEHOLDER|${MYSQL_SECRET_ARN}|g" \
    -e "s|AURORA_SECRET_ARN_PLACEHOLDER|${AURORA_SECRET_ARN}|g" \
    "${SETUP_DIR}/03_metadata_seed.sql"
log "03_metadata_seed.sql patched"

# Upload all 4 SQL scripts to S3 under sql/ prefix
log "Uploading SQL scripts to s3://${DEPLOY_BUCKET}/sql/ ..."
aws s3 cp "${SETUP_DIR}/01_mysql_legacy_schema.sql" \
    "s3://${DEPLOY_BUCKET}/sql/01_mysql_legacy_schema.sql" --quiet
aws s3 cp "${SETUP_DIR}/02_aurora_target_schema.sql" \
    "s3://${DEPLOY_BUCKET}/sql/02_aurora_target_schema.sql" --quiet
aws s3 cp "${SETUP_DIR}/03_metadata_seed.sql" \
    "s3://${DEPLOY_BUCKET}/sql/03_metadata_seed.sql" --quiet
log "SQL scripts uploaded to S3"

# Deploy DB setup stack — Custom Resource triggers Lambda which runs the SQL
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/06_db_setup.yaml" \
    --stack-name "${ENV}-db-setup" \
    --parameter-overrides \
        EnvironmentName=${ENV} \
        MySQLEndpoint=${MYSQL_HOST} \
        AuroraEndpoint=${AURORA_HOST} \
        MySQLSecretArn=${MYSQL_SECRET_ARN} \
        AuroraSecretArn=${AURORA_SECRET_ARN} \
        DMSSecretArn=${DMS_SECRET_ARN} \
        DeployBucket=${DEPLOY_BUCKET} \
    --capabilities CAPABILITY_NAMED_IAM \
    --region ${REGION} \
    --no-fail-on-empty-changeset

log "DB Setup stack complete — all SQL scripts executed automatically"
echo ""
info "DBeaver connection details:"
echo "  MySQL  → host: ${MYSQL_HOST}  port: 3306  db: insurance  user: ldcfadmin"
echo "  Aurora → host: ${AURORA_HOST} port: 5432  db: ldcfdb     user: ldcfadmin"
echo ""

# ── Step 6: Pipeline stack ────────────────────────────────────────
step "Step 6/9 — Pipeline stack"
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/03_pipeline.yaml" \
    --stack-name "${ENV}-pipeline" \
    --parameter-overrides \
        EnvironmentName=${ENV} \
        AlertEmail=${ALERT_EMAIL} \
    --capabilities CAPABILITY_IAM \
    --region ${REGION} \
    --no-fail-on-empty-changeset
log "Pipeline stack ready"

LANDING_BUCKET=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-pipeline" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`LandingBucketName`].OutputValue' \
    --output text)
log "Landing bucket: ${LANDING_BUCKET}"

# ── Step 7: Lambda stack ──────────────────────────────────────────
step "Step 7/9 — Lambda stack"
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/04_lambdas.yaml" \
    --stack-name "${ENV}-lambdas" \
    --parameter-overrides \
        EnvironmentName=${ENV} \
        LambdaDeployBucket=${DEPLOY_BUCKET} \
        DBHost=${AURORA_HOST} \
        DBName=ldcfdb \
        AuroraSecretArn=${AURORA_SECRET_ARN} \
    --capabilities CAPABILITY_NAMED_IAM \
    --region ${REGION} \
    --no-fail-on-empty-changeset
log "Lambda stack ready"

# Wire S3 → Lambda 1 with prefix AND suffix filter
LAMBDA1_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-lambdas" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`ClaimCheckLambdaArn`].OutputValue' \
    --output text)

log "Wiring S3 event notification → Lambda 1..."
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
log "S3 → Lambda notification wired (prefix=dms/sync/ suffix=.csv)"

# ── Step 8: DMS stack ─────────────────────────────────────────────
step "Step 8/9 — DMS stack (~10-15 minutes for replication instance)"
aws cloudformation deploy \
    --template-file "${SCRIPT_DIR}/05_dms.yaml" \
    --stack-name "${ENV}-dms" \
    --parameter-overrides \
        EnvironmentName=${ENV} \
        MySQLEndpoint=${MYSQL_HOST} \
        AuroraEndpoint=${AURORA_HOST} \
        DMSUserPassword=${DMS_PASSWORD} \
        AuroraSecretArn=${AURORA_SECRET_ARN} \
        LandingBucketName=${LANDING_BUCKET} \
    --capabilities CAPABILITY_NAMED_IAM \
    --region ${REGION} \
    --no-fail-on-empty-changeset
log "DMS stack ready"

TASK1_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-dms" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`FullLoadTaskArn`].OutputValue' \
    --output text)
TASK2_ARN=$(aws cloudformation describe-stacks \
    --stack-name "${ENV}-dms" --region ${REGION} \
    --query 'Stacks[0].Outputs[?OutputKey==`CDCTaskArn`].OutputValue' \
    --output text)

# ── Step 9: Start DMS Tasks ───────────────────────────────────────
step "Step 9/9 — Start DMS Tasks"

warn "══════════════════════════════════════════════════════════════"
warn "MANUAL STEP 1 — Start DMS Task 1 (Full Load)"
warn "══════════════════════════════════════════════════════════════"
echo ""
echo "Run this command:"
echo ""
echo -e "${YELLOW}aws dms start-replication-task \\"
echo "  --replication-task-arn ${TASK1_ARN} \\"
echo -e "  --start-replication-task-type start-replication${NC}"
echo ""
echo "Monitor until status = stopped:"
echo -e "${YELLOW}watch -n 15 \"aws dms describe-replication-tasks \\"
echo "  --filters Name=replication-task-arn,Values=${TASK1_ARN} \\"
echo -e "  --query 'ReplicationTasks[0].{Status:Status,Progress:ReplicationTaskStats.FullLoadProgressPercent}'\"${NC}"
echo ""
read -p "Press Enter when Task 1 status = stopped (full load complete)..."

warn "══════════════════════════════════════════════════════════════"
warn "MANUAL STEP 2 — Run keyring one-time load"
warn "══════════════════════════════════════════════════════════════"
echo ""
echo "Run on Aurora (use DBeaver or psql):"
echo ""
echo -e "${YELLOW}PGPASSWORD='<your-password>' psql -h ${AURORA_HOST} -U ldcfadmin -d ldcfdb \\"
echo -e "  -f ../setup/04_keyring_oneshot_load.sql${NC}"
echo ""
echo "Or open 04_keyring_oneshot_load.sql in DBeaver (connected to Aurora) and execute."
echo ""
read -p "Press Enter when keyring load complete and counts verified..."

warn "══════════════════════════════════════════════════════════════"
warn "MANUAL STEP 3 — Start DMS Task 2 (CDC ongoing)"
warn "══════════════════════════════════════════════════════════════"
echo ""
echo -e "${YELLOW}aws dms start-replication-task \\"
echo "  --replication-task-arn ${TASK2_ARN} \\"
echo -e "  --start-replication-task-type start-replication${NC}"
echo ""
read -p "Press Enter when Task 2 is running..."

# ── Final summary ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════"
echo "  LDCF POC DEPLOYED AND RUNNING"
echo -e "══════════════════════════════════════════════════════════${NC}"
echo ""
echo "DBeaver connection details:"
echo "  MySQL:  host=${MYSQL_HOST}  port=3306  db=insurance  user=ldcfadmin"
echo "  Aurora: host=${AURORA_HOST} port=5432  db=ldcfdb     user=ldcfadmin"
echo ""
echo "Resources:"
echo "  Landing bucket:  s3://${LANDING_BUCKET}/dms/sync/"
echo "  Deploy bucket:   s3://${DEPLOY_BUCKET}"
echo "  DMS full load:   ${TASK1_ARN}"
echo "  DMS CDC task:    ${TASK2_ARN}"
echo "  MySQL secret:    ${MYSQL_SECRET_ARN}"
echo "  Aurora secret:   ${AURORA_SECRET_ARN}"
echo ""
echo "Test the pipeline (run in DBeaver on MySQL):"
echo "  Run setup/06_cdc_test_transaction.sql -- inserts 1 policy + 2 claims."
echo "  Expect: 1 CSV in s3://${LANDING_BUCKET}/dms/sync/ within ~60s"
echo "  Expect: PROCESSING_SUCCESS rows in DynamoDB ldcf-poc-utilization-log"
echo "  Expect: new rows in Aurora insurance.policy and insurance.claim"
echo ""
echo "Operations:"
echo "  Pause:   ./cleanup.sh"
echo "  Resume:  ./cleanup.sh --resume"
echo "  Destroy: ./cleanup.sh --destroy-all"
echo ""
log "LDCF POC is live."
