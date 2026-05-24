"""
LDCF POC — Lambda 2: Upstream Loader
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566

TRIGGERED BY: Amazon SQS (Claim Check pointer messages)

RESPONSIBILITY:
  Implements all 8 LDCF integrity patterns:
  1. Dual-Sequence Key Partitioning      — enforced by schema
  2. Circular Replication Guard          — datasync_flag check
  3. Last-Write-Wins Conflict Resolution — last_modified comparison
  4. Upsert Tolerance                    — INSERT ON CONFLICT DO UPDATE
  5. Three-Tier DLQ + DynamoDB Audit     — retry + DynamoDB writes
  6. Binary Key Bridging                 — handled at Qlik/DMS config
  7. Metadata-Driven 1-to-Many           — dynamic DML from metadata_rules
  8. Eventual Consistency + Bounded Drift — independent DML transactions

CSV FORMAT (pipe-separated, no header):
  COLUMN1(pos 0) = operation   I/U/D
  COLUMN2(pos 1) = src_table   e.g. claim
  COLUMN3(pos 2) = src_schema  e.g. insurance
  COLUMN4(pos 3) = event_ts    timestamp
  COLUMN5+(pos 4+) = data fields in column_order from metadata_rules

ENVIRONMENT VARIABLES:
  METADATA_SERVICE_LAMBDA  — Lambda 3 function name
  DYNAMODB_AUDIT_TABLE     — audit table name
  DB_SECRET_ARN            — Secrets Manager ARN for Aurora credentials
  DB_HOST                  — Aurora cluster endpoint
  DB_PORT                  — Aurora port (default 5432)
  DB_NAME                  — Database name
  SQS_DLQ_URL              — DLQ URL for failed events
  MAX_RETRIES              — max retries before PERMANENT_FAILED (default 3)
"""

import csv
import io
import json
import os
import logging
import psycopg2
import psycopg2.extras
import boto3
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

from dml_builder    import build_insert_upsert, build_delete, get_pk_values
from audit_service  import write_audit
from conversion_methods import apply_conversion

# ── Structured logging ───────────────────────────────────────────
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── AWS clients ──────────────────────────────────────────────────
s3       = boto3.client('s3')
sqs      = boto3.client('sqs')
lambda_c = boto3.client('lambda')
secrets  = boto3.client('secretsmanager')

# ── Config ───────────────────────────────────────────────────────
METADATA_LAMBDA = os.environ['METADATA_SERVICE_LAMBDA']
DB_SECRET_ARN   = os.environ['DB_SECRET_ARN']
DB_HOST         = os.environ['DB_HOST']
DB_PORT         = int(os.environ.get('DB_PORT', '5432'))
DB_NAME         = os.environ.get('DB_NAME', 'ldcfdb')
DLQ_URL         = os.environ['SQS_DLQ_URL']
MAX_RETRIES     = int(os.environ.get('MAX_RETRIES', '3'))
DELIMITER       = '|'
# CSV fixed column positions (no header row)
COL_OPERATION  = 0
COL_SRC_TABLE  = 1
COL_SRC_SCHEMA = 2
COL_EVENT_TS   = 3
DATA_START_COL = 4  # COLUMN5 onwards = actual data fields

# ── Warm-start cache ─────────────────────────────────────────────
_metadata_cache: Dict[str, Any] = {}
_db_conn = None


def handler(event, context):
    """
    SQS trigger entry point. Processes one SQS message at a time.
    Batch size set to 1 in CloudFormation for clean retry semantics.
    """
    for sqs_record in event.get('Records', []):

        # ── Read retry context from MessageAttributes ────────────
        attrs       = sqs_record.get('messageAttributes', {})
        retry_count = int(attrs.get('retry_count', {}).get('stringValue', '0'))
        is_retry    = attrs.get('is_retry', {}).get('stringValue', 'false') == 'true'

        body = json.loads(sqs_record['body'])
        meta = body.get('metadata', {})
        data = body.get('data', {})

        bucket     = meta['bucket']
        key        = meta['key']
        event_id   = data['event_id']
        src_schema = data.get('src_schema', 'insurance')
        src_table  = data.get('src_table',  'unknown')

        logger.info(json.dumps({
            "event":       "UPSTREAM_LOADER_START",
            "event_id":    event_id,
            "src":         f"{src_schema}.{src_table}",
            "s3_key":      key,
            "retry_count": retry_count,
            "is_retry":    is_retry
        }))

        # ── Get metadata mappings (cached on warm start) ─────────
        mappings = _get_mappings(src_schema, src_table)
        if not mappings:
            logger.warning(json.dumps({
                "event":    "NO_MAPPINGS",
                "event_id": event_id,
                "src":      f"{src_schema}.{src_table}"
            }))
            continue

        # ── Fetch and parse full CSV from S3 ─────────────────────
        rows = _fetch_and_parse_csv(bucket, key, mappings, event_id)
        logger.info(json.dumps({
            "event":    "CSV_PARSED",
            "event_id": event_id,
            "row_count": len(rows)
        }))

        # ── Process each row ─────────────────────────────────────
        conn = _get_db_connection()
        for row_data in rows:
            _process_row(
                event_id=event_id,
                row_data=row_data,
                mappings=mappings,
                event_metadata={**data, **meta},
                conn=conn,
                retry_count=retry_count
            )


def _process_row(
    event_id:       str,
    row_data:       Dict,
    mappings:       List[Dict],
    event_metadata: Dict,
    conn,
    retry_count:    int
):
    """
    Apply all LDCF integrity patterns to one CSV row.
    Each target mapping (1-to-many) processed in load_order sequence.
    Each DML is an INDEPENDENT transaction — Pattern 8.
    """
    operation = row_data.get('_operation', 'I').upper()

    # ── PATTERN 2: Circular Replication Guard ───────────────────
    # Skip INSERT if record was written by cloud (prevent loop)
    datasync = str(row_data.get('datasync_flag') or '').strip().upper()

    if datasync == 'CLOUD' and operation == 'I':
        logger.info(json.dumps({
            "event":    "CIRCULAR_GUARD_SKIP",
            "event_id": event_id,
            "pattern":  "2-circular-guard",
            "reason":   "datasync_flag=CLOUD + operation=I"
        }))
        # Write SKIP to DynamoDB — counts as success, no DLQ
        for mapping in mappings:
            write_audit(
                event_id=event_id,
                status='SKIP',
                event_metadata=event_metadata,
                event_data=row_data,
                dstn_schema=mapping['dstn_schema_nam'],
                dstn_table=mapping['dstn_tbl_nam'],
                map_id=mapping['map_id'],
                retry_count=retry_count
            )
        return

    # ── Process each target mapping in load_order ────────────────
    for mapping in sorted(mappings, key=lambda m: m['load_order']):
        rules      = mapping['rules']
        dstn_schema = mapping['dstn_schema_nam']
        dstn_table  = mapping['dstn_tbl_nam']
        map_id      = mapping['map_id']
        pk_values   = get_pk_values(mapping, row_data)

        # ── PATTERN 3: Last-Write-Wins (UPDATE only, CLOUD flag) ─
        if datasync == 'CLOUD' and operation == 'U':
            if not _should_apply_update(conn, mapping, row_data):
                logger.info(json.dumps({
                    "event":    "LAST_WRITE_WINS_SKIP",
                    "event_id": event_id,
                    "pattern":  "3-last-write-wins",
                    "table":    dstn_table,
                    "pk":       str(pk_values)
                }))
                write_audit(
                    event_id=event_id,
                    status='SKIP',
                    event_metadata=event_metadata,
                    event_data=row_data,
                    dstn_schema=dstn_schema,
                    dstn_table=dstn_table,
                    map_id=map_id,
                    retry_count=retry_count
                )
                continue

        # ── Build DML dynamically from metadata_rules ────────────
        if operation == 'D':
            sql, params = build_delete(mapping, rules, row_data)
        else:  # I or U → upsert (Pattern 4)
            sql, params = build_insert_upsert(mapping, rules, row_data)

        if sql is None:
            logger.warning(json.dumps({
                "event":    "NO_DML_GENERATED",
                "event_id": event_id,
                "table":    dstn_table
            }))
            continue

        # ── Execute as independent transaction (Pattern 8) ───────
        _execute_with_retry(
            event_id=event_id,
            conn=conn,
            sql=sql,
            params=params,
            operation=operation,
            event_metadata=event_metadata,
            event_data=row_data,
            dstn_schema=dstn_schema,
            dstn_table=dstn_table,
            map_id=map_id,
            retry_count=retry_count
        )


def _execute_with_retry(
    event_id, conn, sql, params,
    operation, event_metadata, event_data,
    dstn_schema, dstn_table, map_id, retry_count
):
    """
    Execute one DML as independent transaction.
    Pattern 5: Three-Tier DLQ with DynamoDB Audit.

    On success → DynamoDB SUCCESS (90d TTL).
    On failure → DynamoDB FAILED + send to DLQ (if retry_count < MAX_RETRIES).
    After MAX_RETRIES → DynamoDB PERMANENT_FAILED.
    """
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            rows_affected = cur.rowcount
        conn.commit()

        logger.info(json.dumps({
            "event":         "DML_SUCCESS",
            "event_id":      event_id,
            "table":         dstn_table,
            "operation":     operation,
            "rows_affected": rows_affected,
            "retry_count":   retry_count
        }))

        write_audit(
            event_id=event_id,
            status='SUCCESS',
            event_metadata=event_metadata,
            event_data=event_data,
            dstn_schema=dstn_schema,
            dstn_table=dstn_table,
            map_id=map_id,
            retry_count=retry_count
        )

    except Exception as e:
        conn.rollback()
        new_retry_count = retry_count + 1

        logger.error(json.dumps({
            "event":         "DML_FAILED",
            "event_id":      event_id,
            "table":         dstn_table,
            "operation":     operation,
            "retry_count":   new_retry_count,
            "error":         str(e)[:500]
        }))

        if new_retry_count >= MAX_RETRIES:
            # Permanent failure — write and stop
            write_audit(
                event_id=event_id,
                status='PERMANENT_FAILED',
                event_metadata=event_metadata,
                event_data=event_data,
                dstn_schema=dstn_schema,
                dstn_table=dstn_table,
                map_id=map_id,
                retry_count=new_retry_count,
                error_message=str(e)
            )
            logger.error(json.dumps({
                "event":    "PERMANENT_FAILED",
                "event_id": event_id,
                "table":    dstn_table,
                "message":  "Manual reprocess required from DynamoDB"
            }))
        else:
            # Transient failure — write FAILED and send to DLQ
            write_audit(
                event_id=event_id,
                status='FAILED',
                event_metadata=event_metadata,
                event_data=event_data,
                dstn_schema=dstn_schema,
                dstn_table=dstn_table,
                map_id=map_id,
                retry_count=new_retry_count,
                error_message=str(e)
            )
            _send_to_dlq(event_metadata, event_data, new_retry_count, event_id)


def _should_apply_update(conn, mapping: Dict, row_data: Dict) -> bool:
    """
    Pattern 3: Last-Write-Wins.
    Compare incoming last_modified against current target record.
    Returns True if incoming event is newer (should apply).
    Returns False if stale (skip update).
    """
    if 'last_modified' not in row_data:
        return True  # no timestamp — apply

    schema    = mapping['dstn_schema_nam']
    table     = mapping['dstn_tbl_nam']
    dstn_pks  = [pk.strip() for pk in mapping['dstn_pks'].split(',')]
    src_pks   = [pk.strip() for pk in mapping['src_pks'].split(',')]

    where_clause = ' AND '.join(f"{pk} = %s" for pk in dstn_pks)
    where_values = [row_data.get(sp) for sp in src_pks]

    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                f"SELECT last_modified FROM {schema}.{table} WHERE {where_clause}",
                where_values
            )
            existing = cur.fetchone()

        if not existing:
            return True  # record not found — INSERT allowed

        existing_ts = str(existing['last_modified'])
        incoming_ts = str(row_data.get('last_modified', ''))
        return incoming_ts >= existing_ts

    except Exception as e:
        logger.warning(json.dumps({
            "event":   "LAST_WRITE_WINS_CHECK_ERROR",
            "table":   table,
            "error":   str(e),
            "default": "applying update"
        }))
        return True  # default to applying if check fails


def _fetch_and_parse_csv(
    bucket: str, key: str, mappings: List[Dict], event_id: str
) -> List[Dict]:
    """
    Fetch pipe-separated CSV from S3.
    No header row — positional mapping:
      pos 0 = operation, 1 = src_table, 2 = src_schema, 3 = event_ts
      pos 4+ = data fields mapped by column_order from metadata_rules

    Builds field_name → position lookup from metadata_rules column_order.
    """
    # Build position → field_name mapping from rules
    # Use load_order=1 mapping rules (primary table rules) for column positions
    primary_mapping = min(mappings, key=lambda m: m['load_order'])
    rules_sorted = sorted(primary_mapping['rules'], key=lambda r: r['column_order'])
    # Position 4 = column_order 1 (first data field)
    pos_to_field = {
        DATA_START_COL + i: rule['src_field_name']
        for i, rule in enumerate(rules_sorted)
    }

    try:
        obj  = s3.get_object(Bucket=bucket, Key=key)
        body = obj['Body'].read().decode('utf-8', errors='replace')
    except Exception as e:
        logger.error(json.dumps({
            "event":    "S3_FETCH_ERROR",
            "event_id": event_id,
            "key":      key,
            "error":    str(e)
        }))
        raise

    rows   = []
    reader = csv.reader(io.StringIO(body), delimiter=DELIMITER)

    for line_num, row in enumerate(reader, start=1):
        if len(row) < DATA_START_COL:
            logger.warning(json.dumps({
                "event":    "SHORT_ROW_SKIP",
                "event_id": event_id,
                "line":     line_num,
                "cols":     len(row)
            }))
            continue

        # Build row dict from positional mapping
        row_dict = {
            '_operation':  row[COL_OPERATION].strip().upper(),
            '_src_table':  row[COL_SRC_TABLE].strip().lower(),
            '_src_schema': row[COL_SRC_SCHEMA].strip().lower(),
            '_event_ts':   row[COL_EVENT_TS].strip(),
            'operation':   row[COL_OPERATION].strip().upper()  # also at field level
        }

        # Map data columns by position
        for pos, field_name in pos_to_field.items():
            if pos < len(row):
                row_dict[field_name] = row[pos].strip()
            else:
                row_dict[field_name] = None

        rows.append(row_dict)

    return rows


def _send_to_dlq(event_metadata: Dict, event_data: Dict,
                 retry_count: int, event_id: str) -> None:
    """Send failed event to DLQ for Lambda 4 to requeue."""
    payload = {
        "metadata": event_metadata,
        "data":     {**event_data, "event_id": event_id}
    }
    try:
        sqs.send_message(
            QueueUrl=DLQ_URL,
            MessageBody=json.dumps(payload),
            MessageAttributes={
                "retry_count": {
                    "DataType":    "Number",
                    "StringValue": str(retry_count)
                },
                "is_retry": {
                    "DataType":    "String",
                    "StringValue": "true"
                }
            }
        )
        logger.info(json.dumps({
            "event":       "DLQ_SENT",
            "event_id":    event_id,
            "retry_count": retry_count
        }))
    except Exception as e:
        logger.error(json.dumps({
            "event":    "DLQ_SEND_ERROR",
            "event_id": event_id,
            "error":    str(e)
        }))


def _get_mappings(src_schema: str, src_table: str) -> Optional[List[Dict]]:
    """
    Fetch mappings from Lambda 3 (metadata service).
    Cached in Lambda memory for warm invocations (Pattern — performance).
    """
    cache_key = f"{src_schema}.{src_table}"
    if cache_key in _metadata_cache:
        return _metadata_cache[cache_key]

    logger.info(json.dumps({"event": "METADATA_CACHE_MISS", "key": cache_key}))

    try:
        response = lambda_c.invoke(
            FunctionName=METADATA_LAMBDA,
            InvocationType='RequestResponse',
            Payload=json.dumps({"src_schema": src_schema, "src_table": src_table})
        )
        result   = json.loads(response['Payload'].read())
        mappings = result.get('mappings', [])
        _metadata_cache[cache_key] = mappings
        logger.info(json.dumps({
            "event":         "METADATA_CACHED",
            "key":           cache_key,
            "mapping_count": len(mappings)
        }))
        return mappings
    except Exception as e:
        logger.error(json.dumps({"event": "METADATA_FETCH_ERROR", "error": str(e)}))
        return None


def _get_db_connection():
    """
    Reuse Aurora connection across warm Lambda invocations (performance).
    Reconnects automatically if connection dropped.
    """
    global _db_conn
    try:
        if _db_conn and not _db_conn.closed:
            _db_conn.cursor().execute('SELECT 1')
            return _db_conn
    except Exception:
        _db_conn = None

    import json as _json
    secret = _json.loads(
        secrets.get_secret_value(SecretId=DB_SECRET_ARN)['SecretString']
    )
    _db_conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=secret['username'], password=secret['password'],
        connect_timeout=10,
        options='-c search_path=insurance,metadata,public'
    )
    _db_conn.autocommit = False
    logger.info(json.dumps({"event": "DB_CONNECTED", "host": DB_HOST}))
    return _db_conn
