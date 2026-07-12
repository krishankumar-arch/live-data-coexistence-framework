"""
LDCF POC — Lambda 5: DB Setup Custom Resource
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566

TRIGGERED BY: CloudFormation Custom Resource (runs automatically during deploy.sh)
RESPONSIBILITY:
  Executes all 4 SQL setup scripts in the correct order:
    1. 01_mysql_legacy_schema.sql  — MySQL insurance schema + sample data
    2. DMS replication user         — ldcf_dms_user with required grants
    3. 02_aurora_target_schema.sql  — Aurora insurance + metadata schemas
    4. 03_metadata_seed.sql         — metadata mappings (endpoints pre-patched)

  Replaces MANUAL STEP 1 entirely. Runs once on CloudFormation Create/Update.
  Delete is a no-op — databases are never dropped by this resource.
  All operations are idempotent — safe to re-run on stack Update.

ENVIRONMENT VARIABLES:
  DEPLOY_BUCKET     — S3 bucket holding sql/ scripts
  MYSQL_HOST        — RDS MySQL public endpoint
  AURORA_HOST       — Aurora PostgreSQL cluster endpoint
  MYSQL_SECRET_ARN  — Secrets Manager ARN for MySQL admin credentials
  AURORA_SECRET_ARN — Secrets Manager ARN for Aurora admin credentials
  DMS_SECRET_ARN    — Secrets Manager ARN for DMS replication user password
"""

import json
import os
import time
import logging
import traceback
import urllib.request

import boto3
import pymysql
import psycopg2
import sqlparse

# ── Structured logging ───────────────────────────────────────────
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── AWS clients ──────────────────────────────────────────────────
s3      = boto3.client('s3')
secrets = boto3.client('secretsmanager')

# ── Config from environment ──────────────────────────────────────
DEPLOY_BUCKET     = os.environ['DEPLOY_BUCKET']
MYSQL_HOST        = os.environ['MYSQL_HOST']
AURORA_HOST       = os.environ['AURORA_HOST']
MYSQL_SECRET_ARN  = os.environ['MYSQL_SECRET_ARN']
AURORA_SECRET_ARN = os.environ['AURORA_SECRET_ARN']
DMS_SECRET_ARN    = os.environ['DMS_SECRET_ARN']

# MySQL error codes treated as idempotent (already exists / duplicate)
MYSQL_IDEMPOTENT_CODES = {
    1007,   # Can't create database — already exists
    1008,   # Can't drop database — doesn't exist
    1050,   # Table already exists
    1051,   # Unknown table (DROP IF EXISTS)
    1060,   # Duplicate column
    1061,   # Duplicate key name
    1062,   # Duplicate entry (INSERT with unique violation)
    1396,   # CREATE USER failed — user already exists
}


# ════════════════════════════════════════════════════════════════
# ENTRY POINT
# ════════════════════════════════════════════════════════════════

def handler(event, context):
    request_type = event.get('RequestType', 'Create')
    logger.info(json.dumps({
        "event":        "DB_SETUP_START",
        "request_type": request_type
    }))

    try:
        if request_type == 'Delete':
            # Never drop databases on stack delete — data is precious
            logger.info(json.dumps({"event": "DB_SETUP_DELETE_NOOP"}))
            cfn_send(event, 'SUCCESS', 'Delete is a no-op — databases preserved')
            return

        # ── Fetch credentials ────────────────────────────────────
        mysql_creds  = get_secret(MYSQL_SECRET_ARN)
        aurora_creds = get_secret(AURORA_SECRET_ARN)
        dms_creds    = get_secret(DMS_SECRET_ARN)

        # ── Step 1: MySQL legacy schema + sample data ────────────
        mysql_sql = fetch_sql('01_mysql_legacy_schema.sql')
        run_mysql(mysql_creds, mysql_sql)
        logger.info(json.dumps({"event": "STEP_COMPLETE", "step": "01_mysql_schema"}))

        # ── Step 2: DMS replication user ─────────────────────────
        create_dms_user(mysql_creds, dms_creds['password'])
        logger.info(json.dumps({"event": "STEP_COMPLETE", "step": "02_dms_user"}))

        # ── Step 3: Aurora target schema ─────────────────────────
        aurora_schema_sql = fetch_sql('02_aurora_target_schema.sql')
        run_psql(aurora_creds, aurora_schema_sql)
        logger.info(json.dumps({"event": "STEP_COMPLETE", "step": "03_aurora_schema"}))

        # ── Step 4: Metadata seed (endpoints already patched) ────
        metadata_sql = fetch_sql('03_metadata_seed.sql')
        run_psql(aurora_creds, metadata_sql)
        logger.info(json.dumps({"event": "STEP_COMPLETE", "step": "04_metadata_seed"}))

        logger.info(json.dumps({"event": "DB_SETUP_SUCCESS"}))
        cfn_send(event, 'SUCCESS', 'All 4 SQL scripts executed successfully')

    except Exception as e:
        logger.error(json.dumps({
            "event":  "DB_SETUP_FAILED",
            "error":  str(e),
            "trace":  traceback.format_exc()[:2000]
        }))
        cfn_send(event, 'FAILED', str(e)[:300])


# ════════════════════════════════════════════════════════════════
# MYSQL HELPERS
# ════════════════════════════════════════════════════════════════

def run_mysql(creds: dict, sql: str) -> None:
    """
    Execute a full MySQL SQL file.
    Handles USE statements by switching the active database.
    Idempotent: duplicate / already-exists errors are silently skipped.
    """
    conn = mysql_connect(creds, db=None)
    try:
        with conn.cursor() as cur:
            for stmt in split_sql(sql):
                upper = stmt.upper().lstrip()
                if upper.startswith('USE '):
                    # Switch active database
                    db_name = stmt.split()[1].rstrip(';').strip('`').strip('"')
                    conn.select_db(db_name)
                    logger.info(json.dumps({"event": "MYSQL_USE_DB", "db": db_name}))
                    continue
                exec_mysql(cur, stmt)
    finally:
        conn.close()


def create_dms_user(admin_creds: dict, dms_password: str) -> None:
    """Create ldcf_dms_user with required replication grants."""
    conn = mysql_connect(admin_creds, db='insurance')
    try:
        with conn.cursor() as cur:
            statements = [
                f"CREATE USER IF NOT EXISTS 'ldcf_dms_user'@'%' IDENTIFIED BY '{dms_password}'",
                # ALTER USER always syncs the password even if the user already existed.
                # Fixes the case where deploy.sh was re-run with a different DMS password
                # but db_setup was skipped (stack already existed) — leaving a stale password.
                f"ALTER USER 'ldcf_dms_user'@'%' IDENTIFIED BY '{dms_password}'",
                "GRANT REPLICATION CLIENT ON *.* TO 'ldcf_dms_user'@'%'",
                "GRANT REPLICATION SLAVE  ON *.* TO 'ldcf_dms_user'@'%'",
                "GRANT SELECT             ON *.* TO 'ldcf_dms_user'@'%'",
                "CALL mysql.rds_set_configuration('binlog retention hours', 24)",
                "FLUSH PRIVILEGES",
            ]
            for stmt in statements:
                exec_mysql(cur, stmt)
    finally:
        conn.close()


def exec_mysql(cur, stmt: str) -> None:
    """Execute one MySQL statement. Skips idempotent errors."""
    try:
        cur.execute(stmt)
        logger.debug(json.dumps({"event": "MYSQL_OK", "stmt_preview": stmt[:80]}))
    except pymysql.err.OperationalError as e:
        code = e.args[0]
        if code in MYSQL_IDEMPOTENT_CODES:
            logger.info(json.dumps({
                "event":  "MYSQL_SKIP_IDEMPOTENT",
                "code":   code,
                "detail": str(e)[:200]
            }))
        else:
            raise
    except pymysql.err.IntegrityError as e:
        # 1062 duplicate entry on INSERT
        if e.args[0] == 1062:
            logger.info(json.dumps({"event": "MYSQL_SKIP_DUPLICATE", "detail": str(e)[:200]}))
        else:
            raise


def mysql_connect(creds: dict, db=None, retries: int = 3):
    """Connect to MySQL with retry backoff."""
    kwargs = dict(
        host=MYSQL_HOST, port=3306,
        user=creds['username'], password=creds['password'],
        charset='utf8mb4', autocommit=True,
        connect_timeout=30
    )
    if db:
        kwargs['database'] = db

    for attempt in range(retries):
        try:
            return pymysql.connect(**kwargs)
        except Exception as e:
            if attempt < retries - 1:
                wait = 15 * (attempt + 1)
                logger.info(json.dumps({
                    "event":   "MYSQL_CONNECT_RETRY",
                    "attempt": attempt + 1,
                    "wait_s":  wait,
                    "error":   str(e)
                }))
                time.sleep(wait)
            else:
                raise


# ════════════════════════════════════════════════════════════════
# POSTGRESQL HELPERS
# ════════════════════════════════════════════════════════════════

def run_psql(creds: dict, sql: str) -> None:
    """
    Execute a full PostgreSQL SQL file.
    Runs each statement in its own autocommit transaction.
    Idempotent: 'already exists' / 'duplicate key' errors are skipped.
    Dollar-quoted DO $$ ... $$ blocks handled correctly by sqlparse.
    """
    conn = psql_connect(creds, dbname='ldcfdb')
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            for stmt in split_sql(sql):
                exec_psql(cur, stmt)
    finally:
        conn.close()


def exec_psql(cur, stmt: str) -> None:
    """Execute one PostgreSQL statement. Skips idempotent errors."""
    try:
        cur.execute(stmt)
        logger.debug(json.dumps({"event": "PSQL_OK", "stmt_preview": stmt[:80]}))
    except Exception as e:
        msg = str(e).lower()
        if any(x in msg for x in [
            'already exists',
            'duplicate key value violates unique constraint',
        ]):
            logger.info(json.dumps({
                "event":  "PSQL_SKIP_IDEMPOTENT",
                "detail": str(e)[:200]
            }))
        else:
            raise


def psql_connect(creds: dict, dbname: str, retries: int = 3):
    """Connect to Aurora PostgreSQL with retry backoff."""
    for attempt in range(retries):
        try:
            return psycopg2.connect(
                host=AURORA_HOST, port=5432, dbname=dbname,
                user=creds['username'], password=creds['password'],
                connect_timeout=30,
                sslmode='prefer'
            )
        except Exception as e:
            if attempt < retries - 1:
                wait = 15 * (attempt + 1)
                logger.info(json.dumps({
                    "event":   "PSQL_CONNECT_RETRY",
                    "attempt": attempt + 1,
                    "wait_s":  wait,
                    "error":   str(e)
                }))
                time.sleep(wait)
            else:
                raise


# ════════════════════════════════════════════════════════════════
# SHARED UTILITIES
# ════════════════════════════════════════════════════════════════

def get_secret(arn: str) -> dict:
    """Retrieve and parse a Secrets Manager secret as a dict."""
    return json.loads(
        secrets.get_secret_value(SecretId=arn)['SecretString']
    )


def fetch_sql(filename: str) -> str:
    """Download a SQL script from S3 deploy bucket under sql/ prefix."""
    obj = s3.get_object(Bucket=DEPLOY_BUCKET, Key=f'sql/{filename}')
    content = obj['Body'].read().decode('utf-8')
    logger.info(json.dumps({
        "event":    "SQL_FETCHED",
        "file":     filename,
        "bytes":    len(content)
    }))
    return content


def split_sql(sql: str):
    """
    Split a SQL file into individual statements using sqlparse.
    sqlparse correctly handles:
      - PostgreSQL dollar-quoted blocks: DO $$ ... $$
      - Multi-line INSERT / CREATE TABLE statements
      - Comment-only lines
      - Empty statements after stripping
    """
    for raw_stmt in sqlparse.split(sql):
        stmt = raw_stmt.strip()
        if not stmt:
            continue
        # Skip pure comment statements (e.g. lines starting with --)
        parsed = sqlparse.parse(stmt)
        if not parsed:
            continue
        # Check if the statement has any non-comment, non-whitespace tokens
        has_content = any(
            t.ttype not in (
                sqlparse.tokens.Comment.Single,
                sqlparse.tokens.Comment.Multiline,
                sqlparse.tokens.Newline,
                sqlparse.tokens.Whitespace,
                sqlparse.tokens.Punctuation,
            )
            for t in parsed[0].flatten()
        )
        if has_content:
            yield stmt


def cfn_send(event: dict, status: str, message: str) -> None:
    """
    Send a response to the CloudFormation pre-signed ResponseURL.
    Called on both success and failure so the stack never hangs.
    """
    physical_id = event.get('PhysicalResourceId', 'ldcf-db-setup')
    body = json.dumps({
        'Status':             status,
        'Reason':             message,
        'PhysicalResourceId': physical_id,
        'StackId':            event['StackId'],
        'RequestId':          event['RequestId'],
        'LogicalResourceId':  event['LogicalResourceId'],
        'Data':               {'Message': message}
    })
    try:
        req = urllib.request.Request(
            url=event['ResponseURL'],
            data=body.encode('utf-8'),
            method='PUT',
            headers={
                'Content-Type':   '',
                'Content-Length': str(len(body))
            }
        )
        urllib.request.urlopen(req, timeout=30)
        logger.info(json.dumps({
            "event":  "CFN_RESPONSE_SENT",
            "status": status
        }))
    except Exception as e:
        # Log but never raise — a failed response send leaves stack hanging
        logger.error(json.dumps({
            "event": "CFN_RESPONSE_SEND_ERROR",
            "error": str(e)
        }))
