# LDCF POC — Deployment Troubleshooting FAQ

Author: Krishan Kumar | ORCID: 0009-0009-7302-7566  
Accumulated during live deployment sessions. Every error encountered, root cause, and exact fix applied.

---

## Table of Contents

**CloudFormation / Infra**
1. [Em dash in CloudFormation Description causes RDS parameter group failure](#1-em-dash-in-cloudformation-description)
2. [Stack stuck in ROLLBACK_COMPLETE — cannot update](#2-stack-stuck-in-rollback_complete)
3. [WithExpressConfiguration — invalid CloudFormation property for Aurora](#3-withexpressconfiguration-invalid-cloudformation-property)
4. [RDS password rejected — invalid characters](#4-rds-password-rejected-invalid-characters)
5. [deploy.sh — Stack in DELETE_IN_PROGRESS when redeploying too quickly](#5-stack-in-delete_in_progress-when-redeploying-too-quickly)
6. [deploy.sh skips completed stacks on re-run — is this correct?](#6-deploysh-skips-completed-stacks-on-re-run)

**Database Setup**
7. [db_setup Lambda connection timeout (Errno 110) — MySQL unreachable](#7-db_setup-lambda-connection-timeout-errno-110)
8. [db_setup fails with foreign key constraint on claims INSERT](#8-foreign-key-constraint-on-claims-insert)
9. [No changes to deploy — Lambda code not updated](#9-no-changes-to-deploy-lambda-code-not-updated)

**DMS**
10. [DMS parallelLoadThreads invalid for MySQL source](#10-dms-parallelloadthreads-invalid-for-mysql)
11. [DMS t3.micro retired — invalid replication instance class](#11-dms-t3micro-retired)
12. [DMS endpoint Access Denied (NativeError 1045) — wrong password](#12-dms-access-denied-nativeerror-1045)
13. [DMS Full Load Task 1 — should target PostgreSQL, not S3](#13-dms-full-load-task-1-should-target-postgresql)
14. [DMS stack — PostgreSQLSettings not supported in CloudFormation](#14-dms-stack-postgresqlsettings-not-supported-in-cloudformation)
15. [DMS stack — PreserveTransactions requires CdcPath setting](#15-dms-stack-preservetransactions-requires-cdcpath)
16. [DMS full load — no pg_hba.conf entry / no encryption (SSL error)](#16-dms-full-load-no-pg_hbaconf-entry-no-encryption)
17. [DMS full load — Table error on both tables, 0 rows loaded (FK blocks TRUNCATE)](#17-dms-full-load-table-error-fk-blocks-truncate)
18. [DMS CDC — "Failed to init column" / replication ongoing with errors](#18-dms-cdc-failed-to-init-column)
19. [DMS CDC CSV — schema and table appear TWICE per row (duplicate columns)](#19-dms-cdc-csv-duplicate-columns)

**Lambda / Pipeline**
20. [CDC pipeline silent — nothing in DynamoDB or SQS](#20-cdc-pipeline-silent-nothing-in-dynamodb)
21. [Lambda 2 — KeyError: METADATA_SERVICE_LAMBDA on import](#21-lambda-2-keyerror-metadata_service_lambda)
22. [Lambda 2 — ImportModuleError: No module named psycopg2](#22-lambda-2-importmoduleerror-no-module-named-psycopg2)

**Cleanup**
23. [cleanup.sh DELETE_FAILED — DMS replication instance stuck](#23-cleanup-delete_failed-dms-replication-instance-stuck)
24. [cleanup.sh DELETE_FAILED — S3 landing bucket not empty](#24-cleanup-delete_failed-s3-landing-bucket-not-empty)
25. [Network stack DELETE_FAILED — Lambda ENIs blocking subnet and security group](#25-network-stack-delete_failed-lambda-enis-blocking)

**Connectivity**
26. [MySQL not accessible from DBeaver — landed in private subnet](#26-mysql-not-accessible-from-dbeaver)

---

## 1. Em dash in CloudFormation Description

**Symptom**
```
Parameter group description contains invalid characters
```

**Root Cause**
The `Description` field of `AWS::RDS::DBParameterGroup` contained an em dash (`—`, Unicode U+2014). The RDS API rejects non-ASCII characters in parameter group descriptions.

**Fix**
Replace the em dash with a plain hyphen:
```yaml
# Before (broken)
Description: LDCF POC MySQL params — enables CDC for DMS
# After (fixed)
Description: LDCF POC MySQL params - enables CDC for DMS
```

---

## 2. Stack stuck in ROLLBACK_COMPLETE

**Symptom**
```
Stack ldcf-poc-databases is in ROLLBACK_COMPLETE state and cannot be updated.
```

**Root Cause**
A previous deployment failed and CloudFormation rolled back, leaving the stack in `ROLLBACK_COMPLETE`. Stacks in this state cannot be updated — only deleted and recreated.

**Fix**
```bash
aws cloudformation delete-stack --stack-name ldcf-poc-databases
aws cloudformation wait stack-delete-complete --stack-name ldcf-poc-databases
./deploy.sh
```

---

## 3. WithExpressConfiguration — invalid CloudFormation property

**Symptom**
```
Property validation failure: [Value for property /ResourceProperties/WithExpressConfiguration is invalid]
```

**Root Cause**
`WithExpressConfiguration` is a valid DMS API property but not supported in CloudFormation for Aurora Serverless v2 configuration.

**Fix**
Replace Aurora Serverless v2 with a plain `AWS::RDS::DBInstance` (PostgreSQL, db.t3.micro):
```yaml
PostgreSQLInstance:
  Type: AWS::RDS::DBInstance
  Properties:
    DBInstanceClass: db.t3.micro
    Engine: postgres
    EngineVersion: "15"
    DBName: ldcfdb
    AllocatedStorage: "20"
    PubliclyAccessible: true
    MultiAZ: false
```

---

## 4. RDS password rejected — invalid characters

**Symptom**
```
The parameter MasterUserPassword is not a valid password.
Only printable ASCII characters besides '/', '@', '"', ' ' may be used.
```

**Root Cause**
The password entered at the `deploy.sh` prompt contained `/`, `@`, `"`, or a space.

**Fix**
Use only: letters (a-z, A-Z), numbers (0-9), and safe symbols: `! # $ % ^ & * ( ) - _ + =`  
Example safe password: `Ldcf2024#Secure!`

---

## 5. Stack in DELETE_IN_PROGRESS when redeploying too quickly

**Symptom**
```
Stack ldcf-poc-network is in DELETE_IN_PROGRESS state and cannot be updated.
```

**Root Cause**
`deploy.sh` was restarted before the previous stack deletion had finished.

**Fix**
```bash
aws cloudformation wait stack-delete-complete \
  --stack-name ldcf-poc-network --region us-east-1 && echo "Ready"

# Check no stacks in bad states
aws cloudformation list-stacks \
  --stack-status-filter DELETE_FAILED ROLLBACK_COMPLETE ROLLBACK_FAILED \
  --query 'StackSummaries[?starts_with(StackName,`ldcf-poc`)].{Name:StackName,Status:StackStatus}' \
  --output table

./deploy.sh
```

---

## 6. deploy.sh skips completed stacks on re-run — is this correct?

**Answer: Yes — this is by design.**

`deploy.sh` uses `aws cloudformation deploy --no-fail-on-empty-changeset`. Behaviour:

| Stack state | Template changed? | Result |
|---|---|---|
| Does not exist | — | Creates the stack |
| `CREATE_COMPLETE` | No | Skips instantly ("No changes to deploy") |
| `CREATE_COMPLETE` | Yes | Updates with new changes |
| `ROLLBACK_COMPLETE` | Either | **Fails** — delete the stack first |
| `DELETE_FAILED` | Either | **Fails** — force-delete first |

If deploy.sh fails at Step 8 (DMS), re-running skips Steps 1–7 and retries Step 8.  
If the DMS stack is in `ROLLBACK_COMPLETE`:
```bash
aws cloudformation delete-stack --stack-name ldcf-poc-dms --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name ldcf-poc-dms --region us-east-1
./deploy.sh   # Steps 1-7 skip, Step 8 deploys fresh
```

---

## 7. db_setup Lambda connection timeout (Errno 110)

**Symptom**
```
DB_SETUP_FAILED: (2003, "Can't connect to MySQL server on '...' (timed out) (Errno 110)")
```

**Root Cause**
The db_setup Lambda was outside the VPC — no `VpcConfig`. MySQL was in a private subnet and unreachable from the public internet.

**Fix**
Add `VpcConfig` to the db_setup Lambda in `06_db_setup.yaml`:
```yaml
VpcConfig:
  SecurityGroupIds:
    - !ImportValue
      Fn::Sub: "${EnvironmentName}-lambda-sg"
  SubnetIds:
    - !ImportValue
      Fn::Sub: "${EnvironmentName}-private-subnet"
```
Also add `AWSLambdaVPCAccessExecutionRole` to the Lambda's IAM role.

---

## 8. Foreign key constraint on claims INSERT

**Symptom**
```
FAILED (1452, 'Cannot add or update a child row: a foreign key constraint fails
(insurance.claim, CONSTRAINT claim_ibfk_1 FOREIGN KEY (policy_id) ...)
```

**Root Cause**
Two compounding issues: (1) SQL used hardcoded policy_id values but MySQL generated different IDs due to `auto_increment_offset`. (2) RDS cached parameter group values and needed a reboot.

**Fix — Part 1**: Use variable lookups instead of hardcoded IDs:
```sql
SET @pol1 = (SELECT policy_id FROM policy WHERE policy_num = 'POL-2024-0001');
INSERT INTO claim (claim_num, policy_id, ...) VALUES ('CLM-2024-0001', @pol1, ...);
```

**Fix — Part 2**: Reboot MySQL after parameter group change:
```bash
aws rds reboot-db-instance --db-instance-identifier ldcf-poc-mysql-legacy
aws rds wait db-instance-available --db-instance-identifier ldcf-poc-mysql-legacy
```

---

## 9. No changes to deploy — Lambda code not updated

**Symptom**
```
No changes to deploy. Stack ldcf-poc-db-setup is up to date.
```
Lambda code in S3 was updated but CloudFormation didn't redeploy it.

**Root Cause**
CloudFormation detects changes by comparing template parameters — not S3 object content.

**Fix — Option A**: Bump `SetupVersion` in template to force redeploy:
```yaml
SetupVersion: "3"   # increment from previous value
```

**Fix — Option B**: Push code directly via CLI:
```bash
aws lambda update-function-code \
  --function-name ldcf-poc-db-setup \
  --s3-bucket $DEPLOY_BUCKET \
  --s3-key lambda/05_db_setup.zip
aws lambda invoke \
  --function-name ldcf-poc-db-setup \
  --payload '{}' /tmp/response.json
```

---

## 10. DMS parallelLoadThreads invalid for MySQL

**Symptom**
```
Invalid value 'parallelLoadThreads' for extra connection attributes
```

**Root Cause**
`parallelLoadThreads` is only valid for Oracle and PostgreSQL DMS source endpoints.

**Fix**
Remove it from `ExtraConnectionAttributes`:
```yaml
ExtraConnectionAttributes: >-
  eventsPollInterval=5;
  initstmt=SET FOREIGN_KEY_CHECKS=0
```

---

## 11. DMS t3.micro Retired

**Symptom**
```
Invalid ReplicationInstance class: dms.t3.micro
```

**Root Cause**
`dms.t3.micro` was retired in DMS engine 3.5+.

**Fix**
```yaml
ReplicationInstanceClass: dms.t3.medium
```
Note: `dms.t3.medium` costs ~$0.068/hr (~$1.63/day). Run `cleanup.sh` between sessions.

---

## 12. DMS Access Denied (NativeError 1045)

**Symptom**
```
NativeError: 1045
Message: Access denied for user 'ldcf_dms_user'@'10.0.1.103' (using password: YES)
```

**Root Cause**
Multiple `deploy.sh` runs used different DMS passwords. `CREATE USER IF NOT EXISTS` silently skipped the user on re-run without updating the password.

**Fix**
Add `ALTER USER` immediately after `CREATE USER IF NOT EXISTS` in the db_setup Lambda:
```python
statements = [
    f"CREATE USER IF NOT EXISTS 'ldcf_dms_user'@'%' IDENTIFIED BY '{dms_password}'",
    f"ALTER USER 'ldcf_dms_user'@'%' IDENTIFIED BY '{dms_password}'",  # always syncs
    "GRANT REPLICATION CLIENT ON *.* TO 'ldcf_dms_user'@'%'",
    ...
]
```
Then force the db_setup Lambda to re-run by bumping `SetupVersion` in `06_db_setup.yaml`.

---

## 13. DMS Full Load Task 1 — should target PostgreSQL, not S3

**Symptom**
DMS Task 1 (full load) completed but data landed in S3 CSV instead of Aurora. Lambda pipeline picked up the full-load files as CDC events.

**Root Cause**
Both tasks were using the same S3 target endpoint.

**Fix**
Added `PostgreSQLTargetEndpoint` in `05_dms.yaml` and changed Task 1 to use it:
```yaml
FullLoadTask:
  TargetEndpointArn: !Ref PostgreSQLTargetEndpoint   # was S3TargetEndpoint
```

---

## 14. DMS stack — PostgreSQLSettings not supported in CloudFormation

**Symptom**
```
Property validation failure: [Encountered unsupported properties in {/}: [PostgreSQLSettings]]
```
or:
```
Property validation failure: [SecretsManagerSecretId, SecretsManagerAccessRoleArn]
```

**Root Cause**
`AWS::DMS::Endpoint` in CloudFormation does not support `PostgreSQLSettings` or `SecretsManagerSecretId`/`SecretsManagerAccessRoleArn` at any level.

**Fix**
Use CloudFormation dynamic references to resolve credentials at deploy time:
```yaml
PostgreSQLTargetEndpoint:
  Type: AWS::DMS::Endpoint
  Properties:
    Username: !Sub "{{resolve:secretsmanager:${AuroraSecretArn}:SecretString:username}}"
    Password: !Sub "{{resolve:secretsmanager:${AuroraSecretArn}:SecretString:password}}"
    SslMode: require
```

---

## 15. DMS stack — PreserveTransactions requires CdcPath setting

**Symptom**
```
Feature PreserveTransactions requires cdcPath setting
(Error Code: InvalidParameterCombinationException)
```

**Root Cause**
`PreserveTransactions: true` on an S3 endpoint requires `CdcPath` to store transaction ordering control files.

**Fix**
```yaml
S3Settings:
  BucketFolder: dms/sync          # data files: s3://bucket/dms/sync/CDC_TXN_*.csv
  CdcPath: dms/cdc-control        # control metadata (DMS internal)
  PreserveTransactions: true
```
Lambda 1 triggers on prefix `dms/sync/` suffix `.csv` — only data files, not control files.

---

## 16. DMS full load — no pg_hba.conf entry / no encryption

**Symptom**
```
FATAL: no pg_hba.conf entry for host "10.0.2.172", user "ldcfadmin",
database "ldcfdb", no encryption
```

**Root Cause**
Aurora PostgreSQL enforces SSL (`rds.force_ssl=1`). DMS connected without SSL — no matching `pg_hba.conf` rule.

**Fix — Part 1** — Add `SslMode: require` to CloudFormation endpoint (already in `05_dms.yaml`):
```yaml
PostgreSQLTargetEndpoint:
  Properties:
    SslMode: require
```

**Fix — Part 2** — Update the existing live endpoint without stack redeploy:
```bash
ENDPOINT_ARN=$(aws dms describe-endpoints \
  --filters Name=endpoint-id,Values=ldcf-poc-aurora-target \
  --query 'Endpoints[0].EndpointArn' --output text)

aws dms modify-endpoint \
  --endpoint-arn $ENDPOINT_ARN \
  --ssl-mode require
```

---

## 17. DMS full load — Table error on both tables, 0 rows loaded (FK blocks TRUNCATE)

**Symptom**
```
| Errors | Inserts | Schema    | State       | Table  |
|  0     |  0      | insurance | Table error | claim  |
|  0     |  0      | insurance | Table error | policy |
```

**Root Cause**
`TargetTablePrepMode: TRUNCATE_BEFORE_LOAD` issued `TRUNCATE insurance.policy`. PostgreSQL blocks this because `insurance.claim` holds a FK referencing it — even when `claim` is empty:
```
ERROR: cannot truncate a table referenced in a foreign key constraint
```
With `MaxFullLoadSubTasks: 2` (parallel), both tables failed simultaneously.

**Fix — `05_dms.yaml` (already applied)**
1. `TargetTablePrepMode: DO_NOTHING` — skips TRUNCATE entirely
2. `MaxFullLoadSubTasks: 1` + `load-order` on selection rules — forces sequential load (policy first, then claim)

**Fix — Live task via CLI**
```bash
TASK1_ARN=$(aws cloudformation describe-stacks --stack-name ldcf-poc-dms \
  --query 'Stacks[0].Outputs[?OutputKey==`FullLoadTaskArn`].OutputValue' --output text)

aws dms modify-replication-task \
  --replication-task-arn "$TASK1_ARN" \
  --replication-task-settings '{"FullLoadSettings":{"TargetTablePrepMode":"DO_NOTHING","MaxFullLoadSubTasks":1}}'

sleep 15

aws dms start-replication-task \
  --replication-task-arn "$TASK1_ARN" \
  --start-replication-task-type reload-target
```

**Prevention**
Always use `DO_NOTHING` + `MaxFullLoadSubTasks:1` when FK constraints exist between target tables. Only use `TRUNCATE_BEFORE_LOAD` after running `05a_pre_dms_drop_fk_indexes.sql`.

---

## 18. DMS CDC — "Failed to init column" / replication ongoing with errors

**Symptom**
```
Table 'insurance'.'policy' was errored/suspended.
Failed to init column
Task status: Replication ongoing with errors. No CSV files in S3.
```

**Root Cause — two combined issues**

**Issue A** — DMS metadata expressions `$AR_M_SOURCE_SCHEMA_NAME` / `$AR_M_SOURCE_TABLE_NAME` in `add-column` transformation rules cause `Failed to init column` when combined with `PreserveTransactions: true` on the S3 target.

**Issue B** — `ChangeProcessingTuning` block in task settings. This is only valid for database targets. For S3 targets it caused DMS to attempt batch-apply column initialisation incompatible with `PreserveTransactions` mode.

**Fix — `05_dms.yaml` (already applied)**
1. Removed all transformation rules (`rule-type: transformation`) from CDCTask — DMS with `PreserveTransactions=true` auto-prepends table/schema without any rules (see Issue #19)
2. Removed `ChangeProcessingTuning` block from `ReplicationTaskSettings` entirely

**Manual console fallback** — if CloudFormation CDC task is stuck, create a fresh task via AWS Console:
- Migration type: `Change data capture (CDC)`
- Table mappings: selection rules only (no transformation rules)
- Task settings: leave defaults — do NOT add `ChangeProcessingTuning`

**Prevention**
- Never use `$AR_M` expressions with `PreserveTransactions: true` on S3
- Never include `ChangeProcessingTuning` for S3 targets

---

## 19. DMS CDC CSV — schema and table appear TWICE per row (duplicate columns)

**Symptom**
CSV rows arrive with schema/table duplicated at the end:
```
I|policy|insurance|2026-06-14 16:55:04|1000020|POL-2026-TEST01|...|insurance|policy
```

**Root Cause — three bugs compounding each other**

**Bug A — DMS auto-prepends with PreserveTransactions=true**: With `PreserveTransactions: true`, the DMS S3 target AUTOMATICALLY adds `table_name` at pos 1 and `schema_name` at pos 2 to every CDC row. Combined with `TimestampColumnName` at pos 3, the actual CSV layout is:
```
pos 0: op (I/U/D)
pos 1: table_name  ← DMS auto-added
pos 2: schema_name ← DMS auto-added
pos 3: event_ts    ← TimestampColumnName
pos 4+: MySQL data columns in schema definition order
```

**Bug B — Transformation rules doubled them**: CDCTask had `add-column` rules with hardcoded `'insurance'`, `'policy'`, `'claim'` expressions. Since DMS already auto-prepends these, the transformation rules appended them again at the END of every row.

**Bug C — Lambda 2 read wrong positions**: Lambda 2 used `IDX_SRC_SCHEMA = -3`, `IDX_SRC_TABLE = -2` (negative indices from end), so it was reading data columns as schema/table names.

**Fix — all three fixed**

`05_dms.yaml` CDCTask: removed all transformation rules — selection rules only.

`lambda/02_upstream_loader/handler.py`: replaced negative indices with fixed constants:
```python
COL_SRC_TABLE  = 1    # always pos 1
COL_SRC_SCHEMA = 2    # always pos 2
COL_EVENT_TS   = 3    # always pos 3
DATA_START_COL = 4    # MySQL data columns start here
```

`setup/03_metadata_seed.sql`: `datasync_flag` added as final rule in Map 1 (`column_order=10`) and Map 3 (`column_order=11`) so Pattern 2 Circular Guard can read it.

**Prevention**
With `PreserveTransactions: true` — NEVER add transformation rules for schema/table columns. Use fixed-position absolute constants in Lambda 2, not negative indices.

---

## 20. CDC pipeline silent — nothing in DynamoDB

**Symptom**
DMS CDC writes CSV to S3. Lambda 1 triggers (visible in CloudWatch). But no DynamoDB entries and SQS messages consumed silently.

**Root Cause**
This is the same root cause as Issue #19 Bug C — Lambda 2 was calling `_get_mappings("policy", "insurance")` instead of `_get_mappings("insurance", "policy")` because schema/table positions were swapped. Every row returned `NO_MAPPINGS` and was silently dropped.

**Fix**
Fixed by the constants change described in Issue #19. After redeploying Lambda 2, CloudWatch should show `MAPPINGS_FOUND` for every data row.

---

## 21. Lambda 2 — KeyError: METADATA_SERVICE_LAMBDA on import

**Symptom**
```
[ERROR] Runtime.ImportModuleError: Unable to import module 'handler':
KeyError: 'METADATA_SERVICE_LAMBDA'
```
Lambda 2 crashes on every invocation before `handler()` runs.

**Root Cause**
Line 102 of `handler.py` (at module level, outside any function):
```python
METADATA_LAMBDA = os.environ['METADATA_SERVICE_LAMBDA']
```
This ran at import time. After the metadata warm-up refactor (`_warm_metadata_cache()` queries Aurora directly), Lambda 3 is no longer needed. But the env var read was left in the code and the env var was never set.

**Fix — three changes to `handler.py`**

1. Remove the module-level env var read:
```python
# DELETE this line
METADATA_LAMBDA = os.environ['METADATA_SERVICE_LAMBDA']
```

2. Remove the unused `lambda_c` boto3 client:
```python
# DELETE this line
lambda_c = boto3.client('lambda')
```

3. Replace `_get_mappings()` fallback (which called Lambda 3) with a simple cache lookup — a miss now means the table has no mapping, not a retrieval error.

**Also**: Delete `METADATA_SERVICE_LAMBDA` from the Lambda environment variables in the AWS Console (Configuration → Environment variables). It is no longer referenced.

**Redeploy required**: Rebuild and upload the Lambda 2 zip. See Issue #22 for the correct build command.

---

## 22. Lambda 2 — ImportModuleError: No module named psycopg2

**Symptom**
```
[ERROR] Runtime.ImportModuleError: Unable to import module 'handler':
No module named 'psycopg2'
```

**Root Cause**
`psycopg2` has C extensions that must be compiled for Amazon Linux (Lambda's runtime). Zipping the `.py` source files without installing dependencies — or installing with a plain `pip install` on macOS — produces the wrong binary.

**Fix**
Always build the Lambda zip using the `--platform manylinux2014_x86_64 --only-binary=:all:` flags so pip downloads the pre-compiled Amazon Linux binary:

```bash
BUILD_DIR="/tmp/ldcf-lambda-build/02_upstream_loader"
ZIPFILE="/tmp/ldcf-lambda-build/02_upstream_loader.zip"
SRC="implementation/poc-code/lambda/02_upstream_loader"

rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
cp "$SRC"/*.py "$BUILD_DIR/"

pip3 install \
    -r "$SRC/requirements.txt" \
    -t "$BUILD_DIR" \
    --no-cache-dir \
    --platform manylinux2014_x86_64 \
    --implementation cp \
    --python-version 3.11 \
    --only-binary=:all:

cd "$BUILD_DIR"
zip -r "$ZIPFILE" . --exclude "*.pyc" --exclude "__pycache__/*"
```

The `deploy.sh` `package_lambda()` function already does this correctly. Run `./deploy.sh` to rebuild all Lambdas properly.

**Prevention**
Never manually zip `.py` files without the pip install step. Always use `deploy.sh` or the exact `--platform manylinux2014_x86_64` flags above.

---

## 23. cleanup.sh DELETE_FAILED — DMS replication instance stuck

**Symptom**
```
Stack: ldcf-poc-dms → DELETE_FAILED
```

**Root Cause**
DMS replication instance was in a transitional state — CloudFormation couldn't complete deletion.

**Fix**
Force-delete the instance directly, then retry the stack:
```bash
INST_ARN=$(aws dms describe-replication-instances \
  --query 'ReplicationInstances[?contains(ReplicationInstanceIdentifier,`ldcf`)].ReplicationInstanceArn' \
  --output text)

aws dms delete-replication-instance --replication-instance-arn "$INST_ARN"

for i in $(seq 1 36); do
  STATUS=$(aws dms describe-replication-instances \
    --filters "Name=replication-instance-arn,Values=${INST_ARN}" \
    --query 'ReplicationInstances[0].ReplicationInstanceStatus' \
    --output text 2>/dev/null || echo "deleted")
  [ "$STATUS" = "deleted" ] && break
  echo "Status: $STATUS ($i/36)..."; sleep 5
done

aws cloudformation delete-stack --stack-name ldcf-poc-dms
aws cloudformation wait stack-delete-complete --stack-name ldcf-poc-dms
```

**Prevention**: `cleanup.sh --destroy-all` calls `force_delete_dms_instance` automatically before deleting the DMS stack.

---

## 24. cleanup.sh DELETE_FAILED — S3 landing bucket not empty

**Symptom**
```
Resource handler returned message: "The bucket you tried to delete is not empty"
Stack: ldcf-poc-pipeline → DELETE_FAILED  (LandingBucket)
```

**Root Cause**
CloudFormation cannot delete an S3 bucket that still contains objects (CDC CSV files from testing).

**Fix**
```bash
BUCKET=$(aws cloudformation describe-stack-resources \
  --stack-name ldcf-poc-pipeline \
  --query 'StackResources[?LogicalResourceId==`LandingBucket`].PhysicalResourceId' \
  --output text)

aws s3 rm s3://$BUCKET --recursive
aws cloudformation delete-stack --stack-name ldcf-poc-pipeline
aws cloudformation wait stack-delete-complete --stack-name ldcf-poc-pipeline
```

**Prevention**: `cleanup.sh` has `empty_s3_bucket()` and `empty_stack_buckets()` helpers that automatically empty all S3 buckets in a stack before deletion.

---

## 25. Network stack DELETE_FAILED — Lambda ENIs blocking subnet and security group

**Symptom**
```
Resource handler returned message: "resource sg-0da503e8d63a9889e has a dependent object"
Resource handler returned message: "The subnet 'subnet-...' has dependencies and cannot be deleted"
```

**Root Cause**
Lambda functions inside a VPC create Elastic Network Interfaces (ENIs) that persist for several minutes after deletion. CloudFormation attempts to delete the network stack before AWS cleans them up.

**Fix**
```bash
SG_ID="sg-0da503e8d63a9889e"          # from the error output
SUBNET_ID="subnet-0e553c39ad70b4ccd"   # from the error output

# Delete ENIs on the security group
aws ec2 describe-network-interfaces \
  --filters Name=group-id,Values=$SG_ID \
  --query 'NetworkInterfaces[*].NetworkInterfaceId' \
  --output text | tr '\t' '\n' | while read eni; do
    [ -z "$eni" ] && continue
    ATTACHMENT=$(aws ec2 describe-network-interfaces \
      --network-interface-ids $eni \
      --query 'NetworkInterfaces[0].Attachment.AttachmentId' \
      --output text 2>/dev/null)
    if [ "$ATTACHMENT" != "None" ] && [ -n "$ATTACHMENT" ]; then
      aws ec2 detach-network-interface --attachment-id $ATTACHMENT --force
      sleep 5
    fi
    aws ec2 delete-network-interface --network-interface-id $eni
done

aws cloudformation delete-stack --stack-name ldcf-poc-network --region us-east-1
aws cloudformation wait stack-delete-complete --stack-name ldcf-poc-network --region us-east-1
```

**Prevention**: Always delete `ldcf-poc-lambdas` first and wait 3–5 minutes before deleting `ldcf-poc-network`. Lambda ENI cleanup is asynchronous.

---

## 26. MySQL not accessible from DBeaver

**Symptom**
DBeaver connection to MySQL fails — connection refused or timeout on port 3306.

**Root Cause**
MySQL landed in SubnetB (private, 10.0.2.0/24). The public endpoint resolved to a private IP — unreachable from outside the VPC.

**Fix**
1. Added SubnetC (public, 10.0.3.0/24, us-east-1b) to `01_network.yaml`
2. Changed `DBSubnetGroup` to use SubnetA + SubnetC (both public, different AZs)
3. Delete and recreate the databases stack:
```bash
aws cloudformation delete-stack --stack-name ldcf-poc-databases
aws cloudformation wait stack-delete-complete --stack-name ldcf-poc-databases
./deploy.sh
```

---

*Last updated: 2026-06-14 | LDCF POC live deployment session*
