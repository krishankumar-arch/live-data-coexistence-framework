"""
LDCF POC -- Lambda 4: DLQ Requeue Handler
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
Pattern: Three-Tier DLQ with Tiered Audit Persistence (LDCF Pattern 5)

TRIGGERED BY: SQS Dead Letter Queue
RESPONSIBILITY:
  Read failed events from DLQ.
  Check retry_count MessageAttribute.
  If retry_count < MAX_RETRIES  -> requeue to main SQS with retry_count+1
  If retry_count >= MAX_RETRIES -> Lambda 2 already wrote PERMANENT_FAILED,
                                    log and discard.

STEPS (for utilization/fault table writes):
  Step 1 -- DLQ message received, decision made
  Step 2 -- Requeue sent to main queue

ENVIRONMENT VARIABLES:
  SQS_MAIN_QUEUE_URL   -- main upstream loader queue URL
  MAX_RETRIES          -- max retries (default 3, must match Lambda 2)
  DYNAMODB_UTIL_TABLE  -- utilization table name
  DYNAMODB_FAULT_TABLE -- fault table name
"""

import json
import os
import logging
import boto3

from dynamo_writer import write_utilization, write_fault

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sqs            = boto3.client('sqs')
MAIN_QUEUE_URL = os.environ['SQS_MAIN_QUEUE_URL']
MAX_RETRIES    = int(os.environ.get('MAX_RETRIES', '3'))
FUNCTION_NAME  = os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'ldcf-poc-dlq-requeue')


def handler(event, context):
    """Process DLQ messages -- requeue or discard."""
    requeued  = 0
    discarded = 0

    for record in event.get('Records', []):
        attrs       = record.get('messageAttributes', {})
        retry_count = int(attrs.get('retry_count', {}).get('stringValue', '0'))
        body        = json.loads(record['body'])
        event_id    = body.get('data', {}).get('event_id', 'unknown')

        logger.info(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "DLQ_RECEIVED",
            "step":          1,
            "event_id":      event_id,
            "retry_count":   retry_count
        }))

        if retry_count >= MAX_RETRIES:
            # Lambda 2 already wrote PERMANENT_FAILED to DynamoDB
            # Nothing to do -- log and discard
            logger.warning(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "DLQ_DISCARD_MAX_RETRIES",
                "step":          1,
                "event_id":      event_id,
                "retry_count":   retry_count,
                "message":       "PERMANENT_FAILED already written by upstream loader"
            }))
            # Record discard in fault table for visibility
            write_fault(
                event_id=event_id,
                lambda_name=FUNCTION_NAME,
                step_number=1,
                status='PERMANENT_FAILED',
                error_reason=f"Max retries ({MAX_RETRIES}) exhausted -- discarded from DLQ"
            )
            discarded += 1
            continue

        # Requeue to main queue with incremented retry_count
        new_retry_count = retry_count + 1
        try:
            sqs.send_message(
                QueueUrl=MAIN_QUEUE_URL,
                MessageBody=json.dumps(body),   # payload unchanged
                MessageAttributes={
                    "retry_count": {"DataType": "Number",
                                    "StringValue": str(new_retry_count)},
                    "is_retry":    {"DataType": "String",
                                    "StringValue": "true"}   # signals retry path to Lambda 2
                }
            )
            logger.info(json.dumps({
                "function_name":   FUNCTION_NAME,
                "event":           "DLQ_REQUEUED",
                "step":            2,
                "event_id":        event_id,
                "new_retry_count": new_retry_count
            }))
            write_utilization(
                event_id=event_id,
                lambda_name=FUNCTION_NAME,
                step_number=2,
                status='SUCCESS'
            )
            requeued += 1

        except Exception as e:
            logger.error(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "DLQ_REQUEUE_ERROR",
                "step":          2,
                "event_id":      event_id,
                "error":         str(e)
            }))
            write_fault(
                event_id=event_id,
                lambda_name=FUNCTION_NAME,
                step_number=2,
                status='FAILED',
                error_reason=f"DLQ_REQUEUE_ERROR: {e}"
            )
            raise   # re-raise to leave message in DLQ for retry

    logger.info(json.dumps({
        "function_name": FUNCTION_NAME,
        "event":         "DLQ_HANDLER_COMPLETE",
        "requeued":      requeued,
        "discarded":     discarded
    }))
    return {"requeued": requeued, "discarded": discarded}
