"""
LDCF POC — DynamoDB Audit Service
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
Pattern: Three-Tier DLQ with Tiered Audit Persistence (LDCF Pattern 5)

STATUS values:
  SUCCESS          → operation applied to target successfully
  SKIP             → skipped (circular guard or stale update)
  FAILED           → failed, retry_count < 3, will be retried via DLQ
  PERMANENT_FAILED → all 3 retries exhausted, manual reprocess required

TTL:
  SUCCESS / SKIP        → 90  days
  FAILED / PERM_FAILED  → 180 days

Each record stores BOTH event_metadata AND event_data so an operator
can reprocess any record from DynamoDB alone — no S3 re-fetch needed.
"""

import os
import json
import logging
import boto3
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

dynamodb   = boto3.resource('dynamodb')
TABLE_NAME = os.environ.get('DYNAMODB_AUDIT_TABLE', 'ldcf-poc-replication-audit')
table      = dynamodb.Table(TABLE_NAME)

TTL_SUCCESS_DAYS = int(os.environ.get('TTL_SUCCESS_DAYS', '90'))
TTL_FAILED_DAYS  = int(os.environ.get('TTL_FAILED_DAYS',  '180'))


def write_audit(
    event_id:       str,
    status:         str,           # SUCCESS|SKIP|FAILED|PERMANENT_FAILED
    event_metadata: Dict,          # operation, src_table, src_schema, event_ts, s3_key
    event_data:     Dict,          # actual row data — for reprocessing
    dstn_schema:    str,
    dstn_table:     str,
    map_id:         int,
    retry_count:    int    = 0,
    error_message:  Optional[str] = None
) -> None:
    """
    Write audit record to DynamoDB.
    Stores both event_metadata and event_data for complete reprocessing capability.
    Failures here must NOT block replication — exception is caught and logged.
    """
    now      = datetime.now(timezone.utc)
    ttl_days = TTL_SUCCESS_DAYS if status in ('SUCCESS', 'SKIP') else TTL_FAILED_DAYS
    ttl      = int((now + timedelta(days=ttl_days)).timestamp())

    item = {
        'event_id':       event_id,
        'table_name':     f"{dstn_schema}.{dstn_table}",  # sort key
        'event_metadata': {
            'operation':  event_metadata.get('operation'),
            'src_schema': event_metadata.get('src_schema'),
            'src_table':  event_metadata.get('src_table'),
            'event_ts':   event_metadata.get('event_ts'),
            'bucket':     event_metadata.get('bucket'),
            's3_key':     event_metadata.get('key'),
        },
        'event_data':     event_data,  # full row for reprocessing
        'dstn_schema':    dstn_schema,
        'dstn_table':     dstn_table,
        'map_id':         str(map_id),
        'status':         status,
        'retry_count':    retry_count,
        'reprocess_flag': False,
        'ttl_epoch':      ttl,
        'created_at':     now.isoformat(),
    }

    if error_message:
        item['error_message'] = str(error_message)[:1000]  # DynamoDB item size limit

    try:
        table.put_item(Item=_clean(item))
        logger.debug(json.dumps({
            "event":     "DYNAMODB_AUDIT_WRITE",
            "event_id":  event_id,
            "status":    status,
            "table":     dstn_table,
            "ttl_days":  ttl_days
        }))
    except Exception as e:
        # Audit failure MUST NOT block replication
        logger.error(json.dumps({
            "event":    "DYNAMODB_AUDIT_ERROR",
            "event_id": event_id,
            "status":   status,
            "error":    str(e)
        }))


def _clean(item: Dict) -> Dict:
    """Remove None values — DynamoDB rejects null attributes."""
    cleaned = {}
    for k, v in item.items():
        if v is None:
            continue
        if isinstance(v, dict):
            cleaned[k] = _clean(v)
        else:
            cleaned[k] = v
    return cleaned
