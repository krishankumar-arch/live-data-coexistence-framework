"""
LDCF POC -- Lambda 1: CDC Claim Check Handler
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
Pattern: Claim Check Pattern (LDCF Layer 1)

FUNCTION NAME: ldcf-poc-insurance-dms-cdc

TRIGGERED BY: S3 ObjectCreated event (DMS drops CDC CSV file)

RESPONSIBILITY:
  Read the S3 event metadata ONLY -- never opens the CSV file.
  Builds a lightweight SQS pointer and publishes it.

  SQS message format:
    {
      "metadata": {
        "event_id":  "<uuid>",
        "bucket":    "ldcf-poc-cdc-landing-<account>",
        "key":       "dms/sync/CDC_TXN_20260615143022.csv",
        "timestamp": "2026-06-15T14:30:22.000Z",
        "file_size": 4096
      }
    }

  Lambda 2 uses bucket + key to fetch and process the full CSV.
  One SQS message per S3 file. Payload stays under 1 KB regardless
  of CSV size -- core of the Claim Check Pattern.

  DMS writes one file per committed transaction with PreserveTransactions=true.
  A single CSV file may contain rows from multiple tables. Lambda 2
  routes each row individually using the schema/table embedded per row.

STEPS (for utilization/fault table writes):
  Step 1 -- S3 event received, pointer built
  Step 2 -- SQS message published

ENVIRONMENT VARIABLES:
  SQS_QUEUE_URL        -- main upstream loader queue URL
  DYNAMODB_UTIL_TABLE  -- utilization table name
  DYNAMODB_FAULT_TABLE -- fault table name
"""

import json
import os
import uuid
import logging
import boto3
from datetime import datetime, timezone

from dynamo_writer import write_utilization, write_fault

# -- Logging --------------------------------------------------------------
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# -- AWS clients (reused on warm invocations) -----------------------------
sqs = boto3.client('sqs')

QUEUE_URL     = os.environ['SQS_QUEUE_URL']
FUNCTION_NAME = os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'ldcf-poc-insurance-dms-cdc')


def handler(event, context):
    """
    Entry point -- processes S3 ObjectCreated events.
    Publishes one SQS pointer per CSV file. Never reads file content.
    """
    processed      = 0
    skipped        = 0
    correlation_id = str(uuid.uuid4())

    logger.info(json.dumps({
        "function_name":  FUNCTION_NAME,
        "correlation_id": correlation_id,
        "event":          "CLAIM_CHECK_START",
        "step":           1,
        "record_count":   len(event.get('Records', []))
    }))

    for record in event.get('Records', []):
        bucket     = record['s3']['bucket']['name']
        key        = record['s3']['object']['key']
        file_size  = record['s3']['object'].get('size', 0)
        # S3 event timestamp -- when the object was created
        event_time = record.get('eventTime', datetime.now(timezone.utc).isoformat())
        event_id   = str(uuid.uuid4())

        # -- Step 1: Validate and build pointer ---------------------------
        if not key.lower().endswith('.csv'):
            logger.info(json.dumps({
                "function_name":  FUNCTION_NAME,
                "correlation_id": correlation_id,
                "event":          "SKIP_NON_CSV",
                "step":           1,
                "key":            key
            }))
            skipped += 1
            continue

        logger.info(json.dumps({
            "function_name":   FUNCTION_NAME,
            "correlation_id":  correlation_id,
            "event":           "S3_EVENT_RECEIVED",
            "step":            1,
            "event_id":        event_id,
            "bucket":          bucket,
            "key":             key,
            "file_size_bytes": file_size,
            "event_time":      event_time
        }))

        # -- Step 2: Build SQS Claim Check pointer and publish ------------
        # Payload is metadata only -- Lambda 2 fetches the actual CSV.
        # Payload never modified across retries (clean design).
        message = {
            "metadata": {
                "event_id":  event_id,
                "bucket":    bucket,
                "key":       key,
                "timestamp": event_time,
                "file_size": file_size
            }
        }

        try:
            response = sqs.send_message(
                QueueUrl=QUEUE_URL,
                MessageBody=json.dumps(message),
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
                "function_name":   FUNCTION_NAME,
                "correlation_id":  correlation_id,
                "event":           "SQS_PUBLISHED",
                "step":            2,
                "event_id":        event_id,
                "message_id":      response["MessageId"],
                "bucket":          bucket,
                "key":             key,
                "payload_bytes":   len(json.dumps(message)),
                "file_size_bytes": file_size
            }))

            write_utilization(
                event_id=event_id,
                lambda_name=FUNCTION_NAME,
                step_number=2,
                status='SUCCESS'
            )
            processed += 1

        except Exception as e:
            logger.error(json.dumps({
                "function_name":  FUNCTION_NAME,
                "correlation_id": correlation_id,
                "event":          "SQS_PUBLISH_ERROR",
                "step":           2,
                "event_id":       event_id,
                "key":            key,
                "error":          str(e)
            }))
            write_fault(
                event_id=event_id,
                lambda_name=FUNCTION_NAME,
                step_number=2,
                status='FAILED',
                error_reason=f"SQS_PUBLISH_ERROR: {e}"
            )
            raise

    logger.info(json.dumps({
        "function_name":  FUNCTION_NAME,
        "correlation_id": correlation_id,
        "event":          "CLAIM_CHECK_COMPLETE",
        "processed":      processed,
        "skipped":        skipped
    }))

    return {"statusCode": 200, "processed": processed, "skipped": skipped}
