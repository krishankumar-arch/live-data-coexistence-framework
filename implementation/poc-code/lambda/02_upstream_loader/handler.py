"""
LDCF POC -- Lambda 2: Upstream Loader
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566

TRIGGERED BY: Amazon SQS (Claim Check pointer messages from Lambda 1)

RESPONSIBILITY:
  Implements all 8 LDCF integrity patterns against every row in a CDC CSV file.

  DMS writes one file per committed transaction (PreserveTransactions=true).
  A single CSV file may contain rows from MULTIPLE TABLES in commit order.
  Lambda 2 reads each row, extracts schema/table from the row itself,
  looks up the metadata mapping for that schema.table, and processes the row.

  DMS CDC CSV FORMAT (pipe-separated, no header row):
    pos  0    = operation    (I / U / D)
    pos  1    = table_name   (DMS auto-prepends with PreserveTransactions=true)
    pos  2    = schema_name  (DMS auto-prepends with PreserveTransactions=true)
    pos  3    = event_ts     (DMS TimestampColumnName on S3 endpoint -- always pos 3)
    pos  4..N = actual data columns from MySQL table (in schema definition order)

  NOTE: With PreserveTransactions=true the file also contains:
    B|txn_id|server_id|commit_ts  <- BEGIN marker (first line)
    C|txn_id|server_id|commit_ts  <- COMMIT marker (last line)
  These B/C rows are skipped in _fetch_csv.

  IMPORTANT: table and schema are at FIXED positions 1 and 2 (not appended at
  the end). DMS PreserveTransactions auto-prepends them before data columns.
  Do NOT add transformation rules to CDCTask -- they cause duplicate columns.

INTEGRITY PATTERNS:
  1. Dual-Sequence Key Partitioning      -- enforced by schema (even=MySQL, odd=PostgreSQL)
  2. Circular Replication Guard          -- datasync_flag=CLOUD check per row
  3. Last-Write-Wins Conflict Resolution -- last_modified comparison per row
  4. Upsert Tolerance                    -- INSERT ON CONFLICT DO UPDATE
  5. Three-Tier DLQ + DynamoDB Audit     -- retry + DynamoDB writes
  6. Binary Key Bridging                 -- handled at DMS config level
  7. Metadata-Driven 1-to-Many           -- dynamic DML from metadata_rules per table
  8. Eventual Consistency + Bounded Drift -- independent DML transactions per row

DMS FILE STRUCTURE (PreserveTransactions=true):
  B|txn_id|server_id|commit_ts                      <- BEGIN marker -- SKIPPED
  I|policy|insurance|event_ts|data_col...|data_col  <- policy INSERT row
  I|claim|insurance|event_ts|data_col...|data_col   <- claim INSERT row (same txn)
  C|txn_id|server_id|commit_ts                      <- COMMIT marker -- SKIPPED

  Columns per data row (pipe delimited, no header):
    pos 0    = op (I/U/D)
    pos 1    = table_name  (DMS PreserveTransactions auto-prepend)
    pos 2    = schema_name (DMS PreserveTransactions auto-prepend)
    pos 3    = event_ts    (DMS TimestampColumnName on S3 endpoint)
    pos 4..N = MySQL table columns in schema definition order

STEPS (for utilization/fault table writes):
  Step 1 -- SQS received, CSV fetched from S3, B/C markers skipped
  Step 2 -- Per row: schema/table read from row[1]/row[2], mappings resolved
  Step 3 -- Per row: Circular replication guard (Pattern 2)
  Step 4 -- Per row: Last-write-wins check (Pattern 3)
  Step 5 -- Per row: DML executed (Pattern 4 / 8)
  Step 6 -- Per row: DLQ send on failure (Pattern 5)

ENVIRONMENT VARIABLES:
  DYNAMODB_AUDIT_TABLE     -- audit table name
  DYNAMODB_UTIL_TABLE      -- utilization table name
  DYNAMODB_FAULT_TABLE     -- fault table name
  DB_SECRET_ARN            -- Secrets Manager ARN for Aurora credentials
  DB_HOST                  -- Aurora cluster endpoint
  DB_PORT                  -- Aurora port (default 5432)
  DB_NAME                  -- Database name (default ldcfdb)
  SQS_DLQ_URL              -- DLQ URL for failed events
  MAX_RETRIES              -- max retries before PERMANENT_FAILED (default 3)
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
from typing import Any, Dict, List, Optional

from dml_builder      import build_insert_upsert, build_delete, get_pk_values
from audit_service    import write_audit
from conversion_methods import apply_conversion
from dynamo_writer    import write_utilization, write_fault

# -- Structured logging ---------------------------------------------------
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# -- AWS clients ----------------------------------------------------------
s3      = boto3.client('s3')
sqs     = boto3.client('sqs')
secrets = boto3.client('secretsmanager')

# -- Config ---------------------------------------------------------------
# Metadata is loaded directly from Aurora at cold start (_warm_metadata_cache).
# No METADATA_SERVICE_LAMBDA env var needed — Lambda 3 is not called per row.
DB_SECRET_ARN   = os.environ['DB_SECRET_ARN']
DB_HOST         = os.environ['DB_HOST']
DB_PORT         = int(os.environ.get('DB_PORT', '5432'))
DB_NAME         = os.environ.get('DB_NAME', 'ldcfdb')
DLQ_URL         = os.environ['SQS_DLQ_URL']
MAX_RETRIES     = int(os.environ.get('MAX_RETRIES', '3'))
FUNCTION_NAME   = os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'ldcf-poc-upstream-loader')
DELIMITER       = '|'

# -- DMS CDC CSV column positions (no header row) -------------------------
# One file = one committed transaction. May contain rows from multiple tables.
# With PreserveTransactions=true, DMS S3 target AUTOMATICALLY prepends
# table_name (pos 1) and schema_name (pos 2) before any data columns.
# TimestampColumnName on the S3 endpoint always lands at pos 3.
# MySQL data columns start at pos 4 in EVERY row regardless of table.
COL_OPERATION  = 0    # always pos 0: I / U / D
COL_SRC_TABLE  = 1    # always pos 1: DMS auto-prepends table name  (e.g. policy)
COL_SRC_SCHEMA = 2    # always pos 2: DMS auto-prepends schema name (e.g. insurance)
COL_EVENT_TS   = 3    # always pos 3: S3 endpoint TimestampColumnName (event_ts)
DATA_START_COL = 4    # pos 4+: MySQL data columns in schema definition order
# Minimum valid data row: op(1) + table(1) + schema(1) + ts(1) + >=1 data col = 5
MIN_ROW_LEN    = 5    # rows shorter than this are B/C markers or malformed -- skip
# B/C row first character (PreserveTransactions transaction markers)
DMS_MARKER_OPS = {'B', 'C'}  # Begin and Commit rows -- skip entirely

# -- Warm-start caches ----------------------------------------------------
# _metadata_cache is pre-loaded on cold start by _warm_metadata_cache().
# Key: "src_schema_nam.src_tbl_nam"  (e.g. "insurance.policy")
# Value: list of mapping dicts (one per map_id), each containing:
#   map_id, dstn_schema_nam, dstn_tbl_nam, src_pks, dstn_pks,
#   load_order, stream_type, and a 'rules' list for that mapping.
# One source table maps to MULTIPLE targets (Pattern 7: 1-to-many).
#   insurance.policy -> [map_id=1 -> insurance.policy,
#                        map_id=2 -> insurance.policy_keyring]
#   insurance.claim  -> [map_id=3 -> insurance.claim,
#                        map_id=4 -> insurance.claim_keyring]
_metadata_cache: Dict[str, Any] = {}   # keyed by "schema.table"
_rules_pos_cache: Dict[str, Dict] = {} # keyed by "schema.table", value = {pos: field_name}
_db_conn = None


def handler(event, context):
    """
    SQS trigger entry point. Processes one SQS message (one CSV file) at a time.
    Batch size 1 in CloudFormation for clean retry semantics.
    """
    # -- Warm metadata cache on cold start --------------------------------
    # Loads ALL active mappings (map_master + rules) from Aurora once.
    # Subsequent warm invocations hit the in-memory dict — zero Lambda 3 calls.
    if not _metadata_cache:
        try:
            _warm_metadata_cache()
        except Exception as e:
            logger.warning(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "METADATA_WARMUP_FAILED",
                "error":         str(e),
                "message":       "Cache empty — all rows will return NO_MAPPINGS until next cold start"
            }))

    for sqs_record in event.get('Records', []):

        # -- Read retry context from MessageAttributes -------------------
        attrs       = sqs_record.get('messageAttributes', {})
        retry_count = int(attrs.get('retry_count', {}).get('stringValue', '0'))
        is_retry    = attrs.get('is_retry', {}).get('stringValue', 'false') == 'true'

        body     = json.loads(sqs_record['body'])
        metadata = body.get('metadata', {})

        bucket     = metadata['bucket']
        key        = metadata['key']
        event_id   = metadata.get('event_id', 'unknown')
        timestamp  = metadata.get('timestamp', '')
        file_size  = metadata.get('file_size', 0)

        logger.info(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "UPSTREAM_LOADER_START",
            "step":          1,
            "event_id":      event_id,
            "bucket":        bucket,
            "key":           key,
            "file_size":     file_size,
            "retry_count":   retry_count,
            "is_retry":      is_retry
        }))

        # -- Step 1: Fetch full CSV from S3 ------------------------------
        try:
            rows = _fetch_csv(bucket, key, event_id)
        except Exception as e:
            logger.error(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "S3_FETCH_ERROR",
                "step":          1,
                "event_id":      event_id,
                "key":           key,
                "error":         str(e)
            }))
            write_fault(event_id=event_id, lambda_name=FUNCTION_NAME,
                        step_number=1, status='FAILED',
                        error_reason=f"S3_FETCH_ERROR: {e}")
            raise

        logger.info(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "CSV_FETCHED",
            "step":          1,
            "event_id":      event_id,
            "key":           key,
            "row_count":     len(rows)
        }))
        write_utilization(event_id=event_id, lambda_name=FUNCTION_NAME,
                          step_number=1, status='SUCCESS')

        # -- Sort rows by FK dependency order before processing -----------
        # DMS PreserveTransactions writes rows in MySQL commit order, which
        # may interleave policy and claim rows from the same transaction.
        # FK constraints require all parent rows (policy) to be fully
        # committed before any child rows (claim) attempt an INSERT.
        #
        # Sort key: minimum map_id across all mappings for the source table.
        #   insurance.policy -> min_map_id=1  (maps 1,2)  -> processed 1st
        #   insurance.claim  -> min_map_id=3  (maps 3,4)  -> processed 2nd
        #   unknown table    -> min_map_id=999             -> processed last
        #
        # Stable sort preserves original CSV order within the same table group
        # so UPDATE/DELETE rows for the same table stay in commit sequence.
        def _row_sort_key(raw_row: List[str]) -> int:
            if len(raw_row) <= COL_SRC_SCHEMA:
                return 999
            tbl_key = (f"{raw_row[COL_SRC_SCHEMA].strip().lower()}"
                       f".{raw_row[COL_SRC_TABLE].strip().lower()}")
            maps = _metadata_cache.get(tbl_key, [])
            return min((m['map_id'] for m in maps), default=999)

        rows_sorted = sorted(rows, key=_row_sort_key)   # stable sort

        # Log the sort result if the order changed (i.e. mixed-table file)
        original_keys = [f"{r[COL_SRC_TABLE]}.{r[COL_SRC_SCHEMA]}" for r in rows
                         if len(r) > COL_SRC_SCHEMA]
        sorted_keys   = [f"{r[COL_SRC_TABLE]}.{r[COL_SRC_SCHEMA]}" for r in rows_sorted
                         if len(r) > COL_SRC_SCHEMA]
        if original_keys != sorted_keys:
            logger.info(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "ROWS_REORDERED_FOR_FK",
                "event_id":      event_id,
                "original_order": original_keys,
                "sorted_order":   sorted_keys,
                "message":       "Rows reordered by map_id to satisfy FK dependencies"
            }))

        conn = _get_db_connection()
        tables_seen = set()

        for row_num, raw_row in enumerate(rows_sorted, start=1):
            src_table  = raw_row[COL_SRC_TABLE].strip().lower()
            src_schema = raw_row[COL_SRC_SCHEMA].strip().lower()
            operation  = raw_row[COL_OPERATION].strip().upper()

            # -- Log exactly what was extracted from each CSV row ---------
            # This shows the raw bytes at each fixed position so column
            # mapping issues are immediately visible in CloudWatch.
            logger.info(json.dumps({
                "function_name":   FUNCTION_NAME,
                "event":           "ROW_EXTRACTED",
                "step":            2,
                "event_id":        event_id,
                "row_num":         row_num,
                "total_cols":      len(raw_row),
                "pos_0_op_raw":    raw_row[COL_OPERATION] if len(raw_row) > COL_OPERATION else None,
                "pos_1_table_raw": raw_row[COL_SRC_TABLE]  if len(raw_row) > COL_SRC_TABLE  else None,
                "pos_2_schema_raw":raw_row[COL_SRC_SCHEMA] if len(raw_row) > COL_SRC_SCHEMA else None,
                "pos_3_ts_raw":    raw_row[COL_EVENT_TS]   if len(raw_row) > COL_EVENT_TS   else None,
                "src_table":       src_table,
                "src_schema":      src_schema,
                "operation":       operation,
                "lookup_key":      f"{src_schema}.{src_table}"
            }))

            if not src_schema or not src_table:
                logger.warning(json.dumps({
                    "function_name": FUNCTION_NAME,
                    "event":         "ROW_MISSING_SCHEMA_TABLE",
                    "step":          2,
                    "event_id":      event_id,
                    "row_num":       row_num,
                    "raw":           raw_row[:6]
                }))
                continue

            table_key = f"{src_schema}.{src_table}"
            tables_seen.add(table_key)

            # -- Step 2: Get mappings for this row's schema.table --------
            mappings = _get_mappings(src_schema, src_table, event_id)
            if not mappings:
                logger.warning(json.dumps({
                    "function_name": FUNCTION_NAME,
                    "event":         "NO_MAPPINGS",
                    "step":          2,
                    "event_id":      event_id,
                    "src":           table_key,
                    "row_num":       row_num,
                    "message":       "No active mapping -- row ignored. Check metadata_rules."
                }))
                write_fault(event_id=event_id, lambda_name=FUNCTION_NAME,
                            step_number=2, status='FAILED',
                            error_reason=f"NO_MAPPINGS for {table_key}")
                continue

            # -- Log 1-to-many mapping targets ----------------------------
            # A single source row fans out to ALL target tables in load_order.
            # e.g. insurance.policy -> [insurance.policy, insurance.policy_keyring]
            targets_ordered = [
                f"{m['dstn_schema_nam']}.{m['dstn_tbl_nam']} (map_id={m['map_id']}, order={m['load_order']})"
                for m in sorted(mappings, key=lambda m: m['load_order'])
            ]
            logger.info(json.dumps({
                "function_name":   FUNCTION_NAME,
                "event":           "MAPPINGS_FOUND",
                "step":            2,
                "event_id":        event_id,
                "row_num":         row_num,
                "src":             table_key,
                "mapping_count":   len(mappings),
                "targets":         targets_ordered
            }))

            # Build field dict for this row using pos_to_field for its table
            row_data = _build_row_dict(raw_row, src_schema, src_table, mappings)

            logger.info(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "ROW_PROCESSING",
                "step":          2,
                "event_id":      event_id,
                "row_num":       row_num,
                "src":           table_key,
                "operation":     operation
            }))

            event_metadata = {
                "event_id":  event_id,
                "bucket":    bucket,
                "key":       key,
                "timestamp": timestamp,
                "src_schema": src_schema,
                "src_table":  src_table,
                "operation":  operation
            }

            _process_row(
                event_id=event_id,
                row_data=row_data,
                mappings=mappings,
                event_metadata=event_metadata,
                conn=conn,
                retry_count=retry_count
            )

        logger.info(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "FILE_PROCESSED",
            "event_id":      event_id,
            "key":           key,
            "total_rows":    len(rows),
            "tables_seen":   list(tables_seen)
        }))


def _fetch_csv(bucket: str, key: str, event_id: str) -> List[List[str]]:
    """
    Fetch the full pipe-separated CSV from S3.
    Returns list of raw row arrays (no parsing beyond splitting).
    Skips short rows that can't contain valid data.
    """
    obj  = s3.get_object(Bucket=bucket, Key=key)
    body = obj['Body'].read().decode('utf-8', errors='replace')

    rows   = []
    reader = csv.reader(io.StringIO(body), delimiter=DELIMITER)

    for line_num, row in enumerate(reader, start=1):
        if not row:
            continue

        # Skip DMS PreserveTransactions B (begin) and C (commit) marker rows.
        # These have format: B|txn_id|server_id|timestamp  (only 3-4 cols)
        op_char = row[0].strip().upper()
        if op_char in DMS_MARKER_OPS:
            logger.info(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "DMS_MARKER_SKIP",
                "step":          1,
                "event_id":      event_id,
                "line":          line_num,
                "marker":        op_char
            }))
            continue

        # Skip malformed rows that are too short to contain op + data + meta cols
        if len(row) < MIN_ROW_LEN:
            logger.warning(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "SHORT_ROW_SKIP",
                "step":          1,
                "event_id":      event_id,
                "line":          line_num,
                "cols":          len(row)
            }))
            continue

        rows.append(row)

    return rows


def _build_row_dict(raw_row: List[str], src_schema: str,
                    src_table: str, mappings: List[Dict]) -> Dict:
    """
    Build a field-name -> value dict from a raw CSV row.

    Actual DMS CSV layout per data row (PreserveTransactions=true):
      pos 0            = operation (I/U/D)
      pos 1 .. -4      = actual data columns in MySQL schema definition order
      pos 0            = op (I/U/D)
      pos 1            = table_name  (DMS PreserveTransactions auto-prepend)
      pos 2            = schema_name (DMS PreserveTransactions auto-prepend)
      pos 3            = event_ts    (S3 endpoint TimestampColumnName)
      pos 4..N         = MySQL data columns in schema definition order

    pos_to_field maps 0-based DATA column index -> src_field_name from metadata_rules.
    'data columns' are raw_row[DATA_START_COL:] == raw_row[4:].
    column_order in metadata_rules must match the MySQL schema column sequence exactly.
    """
    cache_key = f"{src_schema}.{src_table}"
    if cache_key not in _rules_pos_cache:
        primary_mapping = min(mappings, key=lambda m: m['load_order'])
        rules_sorted    = sorted(primary_mapping['rules'], key=lambda r: r['column_order'])
        # Map 0-based index within data_cols (raw_row[DATA_START_COL:]) to field name
        _rules_pos_cache[cache_key] = {
            i: rule['src_field_name']
            for i, rule in enumerate(rules_sorted)
        }

    pos_to_field = _rules_pos_cache[cache_key]

    # Extract data columns: all columns after the 4 fixed DMS header columns
    # raw_row layout: [op, table, schema, event_ts, data_col_0, data_col_1, ...]
    # data_cols[0] = MySQL column 1 = matches column_order=1 in metadata_rules
    data_cols = raw_row[DATA_START_COL:]

    row_dict = {
        '_operation':  raw_row[COL_OPERATION].strip().upper(),
        '_src_table':  raw_row[COL_SRC_TABLE].strip().lower(),
        '_src_schema': raw_row[COL_SRC_SCHEMA].strip().lower(),
        '_event_ts':   raw_row[COL_EVENT_TS].strip(),
        'operation':   raw_row[COL_OPERATION].strip().upper()
    }

    for idx, field_name in pos_to_field.items():
        row_dict[field_name] = data_cols[idx].strip() if idx < len(data_cols) else None

    return row_dict


def _process_row(event_id: str, row_data: Dict, mappings: List[Dict],
                 event_metadata: Dict, conn, retry_count: int):
    """
    Apply all LDCF integrity patterns to one CSV row.
    Each target mapping (1-to-many) processed in load_order sequence.
    Each DML is an INDEPENDENT transaction -- Pattern 8.
    """
    operation = row_data.get('_operation', 'I').upper()
    datasync  = str(row_data.get('datasync_flag') or '').strip().upper()

    # -- PATTERN 2: Circular Replication Guard (Step 3) ----------------
    if datasync == 'CLOUD' and operation == 'I':
        logger.info(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "CIRCULAR_GUARD_SKIP",
            "step":          3,
            "event_id":      event_id,
            "pattern":       "2-circular-guard",
            "reason":        "datasync_flag=CLOUD + operation=I"
        }))
        for mapping in mappings:
            write_audit(event_id=event_id, status='SKIP',
                        event_metadata=event_metadata, event_data=row_data,
                        dstn_schema=mapping['dstn_schema_nam'],
                        dstn_table=mapping['dstn_tbl_nam'],
                        map_id=mapping['map_id'], retry_count=retry_count)
            write_utilization(event_id=event_id, lambda_name=FUNCTION_NAME,
                              step_number=3, status='SKIP')
        return

    # -- Process each target mapping in load_order ----------------------
    for mapping in sorted(mappings, key=lambda m: m['load_order']):
        rules       = mapping['rules']
        dstn_schema = mapping['dstn_schema_nam']
        dstn_table  = mapping['dstn_tbl_nam']
        map_id      = mapping['map_id']
        pk_values   = get_pk_values(mapping, row_data)

        # -- PATTERN 3: Last-Write-Wins (Step 4) ----------------------
        if datasync == 'CLOUD' and operation == 'U':
            if not _should_apply_update(conn, mapping, row_data):
                logger.info(json.dumps({
                    "function_name": FUNCTION_NAME,
                    "event":         "LAST_WRITE_WINS_SKIP",
                    "step":          4,
                    "event_id":      event_id,
                    "pattern":       "3-last-write-wins",
                    "table":         dstn_table,
                    "pk":            str(pk_values)
                }))
                write_audit(event_id=event_id, status='SKIP',
                            event_metadata=event_metadata, event_data=row_data,
                            dstn_schema=dstn_schema, dstn_table=dstn_table,
                            map_id=map_id, retry_count=retry_count)
                write_utilization(event_id=event_id, lambda_name=FUNCTION_NAME,
                                  step_number=4, status='SKIP')
                continue

        # -- Build DML from metadata_rules (Step 5) -------------------
        if operation == 'D':
            sql, params = build_delete(mapping, rules, row_data)
        else:
            sql, params = build_insert_upsert(mapping, rules, row_data)

        if sql is None:
            logger.warning(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "NO_DML_GENERATED",
                "step":          5,
                "event_id":      event_id,
                "table":         dstn_table
            }))
            continue

        _execute_with_retry(
            event_id=event_id, conn=conn, sql=sql, params=params,
            operation=operation, event_metadata=event_metadata,
            event_data=row_data, dstn_schema=dstn_schema,
            dstn_table=dstn_table, map_id=map_id, retry_count=retry_count
        )


def _execute_with_retry(event_id, conn, sql, params, operation,
                        event_metadata, event_data, dstn_schema,
                        dstn_table, map_id, retry_count):
    """
    Execute one DML as an independent transaction (Pattern 8).
    Pattern 5: Three-Tier DLQ with DynamoDB Audit.
    """
    # -- Log the generated SQL before executing (Step 5) -----------------
    # Full SQL template + first 8 params so the DML is auditable in CloudWatch.
    # Params are cast to str so timestamps and Decimals serialize cleanly.
    logger.info(json.dumps({
        "function_name":   FUNCTION_NAME,
        "event":           "DML_GENERATED",
        "step":            5,
        "event_id":        event_id,
        "table":           dstn_table,
        "operation":       operation,
        "sql":             sql,
        "param_count":     len(params) if params else 0,
        "params_preview":  [str(p)[:80] for p in (params or [])[:8]]
    }))

    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            rows_affected = cur.rowcount
        conn.commit()

        logger.info(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "DML_SUCCESS",
            "step":          5,
            "event_id":      event_id,
            "table":         dstn_table,
            "operation":     operation,
            "rows_affected": rows_affected,
            "retry_count":   retry_count
        }))
        write_audit(event_id=event_id, status='SUCCESS',
                    event_metadata=event_metadata, event_data=event_data,
                    dstn_schema=dstn_schema, dstn_table=dstn_table,
                    map_id=map_id, retry_count=retry_count)
        write_utilization(event_id=event_id, lambda_name=FUNCTION_NAME,
                          step_number=5, status='SUCCESS')

    except Exception as e:
        conn.rollback()
        new_retry_count = retry_count + 1

        logger.error(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "DML_FAILED",
            "step":          5,
            "event_id":      event_id,
            "table":         dstn_table,
            "operation":     operation,
            "retry_count":   new_retry_count,
            "error":         str(e)[:500]
        }))

        if new_retry_count >= MAX_RETRIES:
            write_audit(event_id=event_id, status='PERMANENT_FAILED',
                        event_metadata=event_metadata, event_data=event_data,
                        dstn_schema=dstn_schema, dstn_table=dstn_table,
                        map_id=map_id, retry_count=new_retry_count,
                        error_message=str(e))
            write_fault(event_id=event_id, lambda_name=FUNCTION_NAME,
                        step_number=5, status='PERMANENT_FAILED',
                        error_reason=str(e))
            logger.error(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "PERMANENT_FAILED",
                "step":          5,
                "event_id":      event_id,
                "table":         dstn_table,
                "message":       "Manual reprocess required from DynamoDB fault table"
            }))
        else:
            write_audit(event_id=event_id, status='FAILED',
                        event_metadata=event_metadata, event_data=event_data,
                        dstn_schema=dstn_schema, dstn_table=dstn_table,
                        map_id=map_id, retry_count=new_retry_count,
                        error_message=str(e))
            write_fault(event_id=event_id, lambda_name=FUNCTION_NAME,
                        step_number=5, status='FAILED', error_reason=str(e))
            _send_to_dlq(event_metadata, new_retry_count, event_id)


def _should_apply_update(conn, mapping: Dict, row_data: Dict) -> bool:
    """Pattern 3: Last-Write-Wins -- returns True if incoming event is newer."""
    if 'last_modified' not in row_data:
        return True

    schema   = mapping['dstn_schema_nam']
    table    = mapping['dstn_tbl_nam']
    dstn_pks = [pk.strip() for pk in mapping['dstn_pks'].split(',')]
    src_pks  = [pk.strip() for pk in mapping['src_pks'].split(',')]

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
            return True
        return str(row_data.get('last_modified', '')) >= str(existing['last_modified'])
    except Exception as e:
        logger.warning(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "LAST_WRITE_WINS_CHECK_ERROR",
            "step":          4,
            "table":         table,
            "error":         str(e),
            "default":       "applying update"
        }))
        return True


def _send_to_dlq(event_metadata: Dict, retry_count: int, event_id: str) -> None:
    """Send failed event to DLQ for Lambda 4 to requeue."""
    payload = {"metadata": {**event_metadata, "event_id": event_id}}
    try:
        sqs.send_message(
            QueueUrl=DLQ_URL,
            MessageBody=json.dumps(payload),
            MessageAttributes={
                "retry_count": {"DataType": "Number",
                                "StringValue": str(retry_count)},
                "is_retry":    {"DataType": "String",
                                "StringValue": "true"}
            }
        )
        logger.info(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "DLQ_SENT",
            "step":          6,
            "event_id":      event_id,
            "retry_count":   retry_count
        }))
        write_fault(event_id=event_id, lambda_name=FUNCTION_NAME,
                    step_number=6, status='DLQ',
                    error_reason=f"Sent to DLQ, retry_count={retry_count}")
    except Exception as e:
        logger.error(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "DLQ_SEND_ERROR",
            "step":          6,
            "event_id":      event_id,
            "error":         str(e)
        }))
        write_fault(event_id=event_id, lambda_name=FUNCTION_NAME,
                    step_number=6, status='FAILED',
                    error_reason=f"DLQ_SEND_ERROR: {e}")


def _get_mappings(src_schema: str, src_table: str,
                  event_id: str) -> Optional[List[Dict]]:
    """
    Return pre-loaded mappings from the in-memory cache.

    _warm_metadata_cache() loads ALL active mappings from Aurora at cold start.
    A cache miss here means the table genuinely has no active mapping defined
    in metadata_map_master — not a retrieval error. Return None so the caller
    logs NO_MAPPINGS and skips the row.
    """
    cache_key = f"{src_schema}.{src_table}"
    mappings  = _metadata_cache.get(cache_key)

    if not mappings:
        logger.warning(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "METADATA_CACHE_MISS",
            "step":          2,
            "event_id":      event_id,
            "key":           cache_key,
            "message":       "No mapping in cache — table not in metadata_map_master or warmup failed"
        }))
        return None

    return mappings


def _get_db_connection():
    """Reuse Aurora connection across warm invocations. Reconnects if dropped."""
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
    logger.info(json.dumps({
        "function_name": FUNCTION_NAME,
        "event":         "DB_CONNECTED",
        "host":          DB_HOST
    }))
    return _db_conn


def _warm_metadata_cache(event_id: str = "COLD_START") -> None:
    """
    Pre-load ALL active metadata into _metadata_cache at Lambda cold start.

    Queries metadata.metadata_map_master JOIN metadata.metadata_rules directly
    from Aurora — no Lambda 3 round-trip needed during row processing.

    Cache structure (keyed by "src_schema_nam.src_tbl_nam"):
      {
        "insurance.policy": [
          { map_id:1, dstn_schema_nam:"insurance", dstn_tbl_nam:"policy",
            src_pks:"policy_id", dstn_pks:"policy_id",
            load_order:1, stream_type:"BOTH",
            rules: [ {src_field_name, dstn_field_name, conversion_method,
                      conversion_format_txt, column_order, ...}, ... ] },
          { map_id:2, dstn_schema_nam:"insurance", dstn_tbl_nam:"policy_keyring",
            ...10 rules for keyring... }
        ],
        "insurance.claim": [
          { map_id:3, ... rules for claim ... },
          { map_id:4, ... rules for claim_keyring ... }
        ]
      }

    A single source row therefore fans out to ALL entries in the list,
    applied in ascending load_order (Pattern 7: Metadata-Driven 1-to-Many).
    """
    global _metadata_cache

    conn = _get_db_connection()

    sql = """
        SELECT
            m.map_id,
            m.src_schema_nam,
            m.src_tbl_nam,
            m.dstn_schema_nam,
            m.dstn_tbl_nam,
            m.src_pks,
            m.dstn_pks,
            m.load_order,
            m.stream_type,
            r.rule_id,
            r.src_field_name,
            r.src_datatype_txt,
            r.dstn_field_name,
            r.dstn_datatype_txt,
            r.conversion_method,
            r.conversion_format_txt,
            r.column_order
        FROM  metadata.metadata_map_master m
        JOIN  metadata.metadata_rules r ON r.map_id = m.map_id
        WHERE m.is_active = true
        ORDER BY m.src_schema_nam, m.src_tbl_nam,
                 m.load_order, r.column_order
    """

    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(sql)
        db_rows = cur.fetchall()

    # ── Build maps_by_id: map_id -> mapping dict with rules list ─────────
    maps_by_id: Dict[int, Dict] = {}
    for row in db_rows:
        mid = row['map_id']
        if mid not in maps_by_id:
            maps_by_id[mid] = {
                'map_id':          mid,
                'src_schema_nam':  row['src_schema_nam'],
                'src_tbl_nam':     row['src_tbl_nam'],
                'dstn_schema_nam': row['dstn_schema_nam'],
                'dstn_tbl_nam':    row['dstn_tbl_nam'],
                'src_pks':         row['src_pks'],
                'dstn_pks':        row['dstn_pks'],
                'load_order':      row['load_order'],
                'stream_type':     row['stream_type'],
                'rules':           []
            }
        maps_by_id[mid]['rules'].append({
            'rule_id':               row['rule_id'],
            'src_field_name':        row['src_field_name'],
            'src_datatype_txt':      row['src_datatype_txt'],
            'dstn_field_name':       row['dstn_field_name'],
            'dstn_datatype_txt':     row['dstn_datatype_txt'],
            'conversion_method':     row['conversion_method'],
            'conversion_format_txt': row['conversion_format_txt'],
            'column_order':          row['column_order'],
        })

    # ── Group by cache key: "src_schema.src_table" -> [map dicts] ────────
    new_cache: Dict[str, List] = {}
    for map_dict in maps_by_id.values():
        cache_key = f"{map_dict['src_schema_nam']}.{map_dict['src_tbl_nam']}"
        if cache_key not in new_cache:
            new_cache[cache_key] = []
        new_cache[cache_key].append(map_dict)

    _metadata_cache = new_cache

    # ── Summary log ───────────────────────────────────────────────────────
    summary = {
        k: [f"map_id={m['map_id']} -> {m['dstn_schema_nam']}.{m['dstn_tbl_nam']} "
            f"(load_order={m['load_order']}, {len(m['rules'])} rules)"
            for m in sorted(v, key=lambda x: x['load_order'])]
        for k, v in new_cache.items()
    }
    logger.info(json.dumps({
        "function_name":  FUNCTION_NAME,
        "event":          "METADATA_PRELOADED",
        "event_id":       event_id,
        "tables_loaded":  list(new_cache.keys()),
        "total_maps":     len(maps_by_id),
        "total_rules":    len(db_rows),
        "mapping_summary": summary
    }))
