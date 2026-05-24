"""
LDCF POC — Lambda 1: Claim Check Handler
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
Pattern: Claim Check Pattern (LDCF Layer 1)

TRIGGERED BY: S3 ObjectCreated event
RESPONSIBILITY:
  1. Receive S3 event when DMS drops a CDC CSV file
  2. Read FIRST DATA ROW of CSV to extract routing metadata
     (COLUMN1=operation, COLUMN2=src_table, COLUMN3=src_schema,
      COLUMN4=event_ts — no header row, pipe-separated)
  3. Build lightweight SQS pointer — NEVER passes CSV content
  4. Publish pointer to SQS with retry_count=0, is_retry=false

PERFORMANCE:
  - Reads only first row of CSV for metadata extraction
  - Message body stays under 1KB regardless of CSV file size
  - Bypasses SQS 256KB hard limit entirely (Claim Check Pattern)

ENVIRONMENT VARIABLES:
  SQS_QUEUE_URL   — main upstream loader queue URL
"""

import json
import csv
import io
import os
import uuid
import logging
import boto3
from datetime import datetime, timezone

# ── Structured logging ───────────────────────────────────────────
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── AWS clients (module-level = reused on warm invocations) ──────
s3  = boto3.client('s3')
sqs = boto3.client('sqs')

QUEUE_URL   = os.environ['SQS_QUEUE_URL']
DELIMITER   = '|'   # DMS pipe-separated output
# CSV column positions (no header row)
COL_OPERATION  = 0  # I / U / D
COL_SRC_TABLE  = 1  # e.g. claim
COL_SRC_SCHEMA = 2  # e.g. insurance
COL_EVENT_TS   = 3  # timestamp from DMS


def handler(event, context):
    """
    Entry point — processes S3 ObjectCreated events.
    One SQS message published per CSV file.
    """
    processed = 0
    skipped   = 0
    correlation_id = str(uuid.uuid4())  # ties log entries together

    logger.info(json.dumps({
        "correlation_id": correlation_id,
        "event":          "CLAIM_CHECK_START",
        "record_count":   len(event.get('Records', []))
    }))

    for record in event.get('Records', []):
        bucket    = record['s3']['bucket']['name']
        key       = record['s3']['object']['key']
        file_size = record['s3']['object'].get('size', 0)

        if not key.lower().endswith('.csv'):
            logger.info(json.dumps({
                "correlation_id": correlation_id,
                "event": "SKIP_NON_CSV", "key": key
            }))
            skipped += 1
            continue

        try:
            routing = _extract_routing_from_csv(bucket, key, correlation_id)
        except Exception as e:
            logger.error(json.dumps({
                "correlation_id": correlation_id,
                "event": "CSV_PARSE_ERROR",
                "bucket": bucket, "key": key, "error": str(e)
            }))
            raise  # re-raise to trigger Lambda retry

        # ── Build Claim Check pointer ────────────────────────────
        # Payload stays under 1KB — core of Claim Check Pattern
        # Payload is NEVER modified across retries (clean design)
        payload = {
            "metadata": {
                "bucket":    bucket,
                "key":       key,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "file_size": file_size
            },
            "data": {
                "event_id":  str(uuid.uuid4()),  # stays same across all retries
                "operation":  routing["operation"],
                "src_table":  routing["src_table"],
                "src_schema": routing["src_schema"],
                "event_ts":   routing["event_ts"]
            }
        }

        try:
            response = sqs.send_message(
                QueueUrl=QUEUE_URL,
                MessageBody=json.dumps(payload),
                # MessageAttributes travel separately — payload stays clean
                MessageAttributes={
                    "retry_count": {
                        "DataType":    "Number",
                        "StringValue": "0"
                    },
                    "is_retry": {
                        "DataType":    "String",
                        "StringValue": "false"
                    }
                }
            )
            logger.info(json.dumps({
                "correlation_id": correlation_id,
                "event":          "SQS_PUBLISHED",
                "message_id":     response["MessageId"],
                "src_table":      routing["src_table"],
                "operation":      routing["operation"],
                "payload_bytes":  len(json.dumps(payload)),
                "file_size_bytes": file_size
            }))
            processed += 1

        except Exception as e:
            logger.error(json.dumps({
                "correlation_id": correlation_id,
                "event": "SQS_PUBLISH_ERROR",
                "key": key, "error": str(e)
            }))
            raise

    logger.info(json.dumps({
        "correlation_id": correlation_id,
        "event":          "CLAIM_CHECK_COMPLETE",
        "processed":      processed,
        "skipped":        skipped
    }))

    return {"statusCode": 200, "processed": processed, "skipped": skipped}


def _extract_routing_from_csv(bucket: str, key: str, correlation_id: str) -> dict:
    """
    Read only the FIRST data row of the pipe-separated CSV.
    No header row — positional column mapping:
      COLUMN1 (pos 0) = DMS operation  (I/U/D)
      COLUMN2 (pos 1) = source table   (claim/policy)
      COLUMN3 (pos 2) = source schema  (insurance)
      COLUMN4 (pos 3) = event timestamp

    Reads minimum bytes from S3 using Range header for performance.
    """
    # Read first 2KB — enough to get the first row without loading whole file
    try:
        obj  = s3.get_object(Bucket=bucket, Key=key, Range='bytes=0-2047')
        data = obj['Body'].read().decode('utf-8', errors='replace')
    except Exception as e:
        raise RuntimeError(f"S3 read failed for {bucket}/{key}: {e}")

    reader = csv.reader(io.StringIO(data), delimiter=DELIMITER)
    for row in reader:
        if len(row) < 4:
            logger.warning(json.dumps({
                "correlation_id": correlation_id,
                "event": "SHORT_ROW", "row_len": len(row), "key": key
            }))
            continue

        return {
            "operation":  row[COL_OPERATION].strip().upper(),
            "src_table":  row[COL_SRC_TABLE].strip().lower(),
            "src_schema": row[COL_SRC_SCHEMA].strip().lower(),
            "event_ts":   row[COL_EVENT_TS].strip()
        }

    raise RuntimeError(f"No valid rows found in {key}")
