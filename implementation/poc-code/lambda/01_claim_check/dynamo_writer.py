"""
LDCF POC — DynamoDB Utilization & Fault Writer
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566

Shared by all Lambda functions.

Writes to two tables:
  DYNAMODB_UTIL_TABLE  (ldcf-poc-utilization)
    → SUCCESS and SKIP events — every step that completes normally
    PK: event_id   SK: lambda_step ("lambda_name#step_number")

  DYNAMODB_FAULT_TABLE (ldcf-poc-fault)
    → FAILED, PERMANENT_FAILED, DLQ events
    PK: event_id   SK: lambda_step ("lambda_name#step_number")

RULE: Failures here MUST NOT block the main data pipeline.
      All exceptions are caught and logged only.
"""

import os
import json
import logging
from datetime import datetime, timezone

import boto3

logger     = logging.getLogger(__name__)
_dynamodb  = boto3.resource('dynamodb')

UTIL_TABLE_NAME  = os.environ.get('DYNAMODB_UTIL_TABLE',  'ldcf-poc-utilization')
FAULT_TABLE_NAME = os.environ.get('DYNAMODB_FAULT_TABLE', 'ldcf-poc-fault')

# Module-level table references reused across warm invocations
_util_table  = None
_fault_table = None


def _get_util_table():
    global _util_table
    if _util_table is None:
        _util_table = _dynamodb.Table(UTIL_TABLE_NAME)
    return _util_table


def _get_fault_table():
    global _fault_table
    if _fault_table is None:
        _fault_table = _dynamodb.Table(FAULT_TABLE_NAME)
    return _fault_table


def write_utilization(
    event_id:    str,
    lambda_name: str,
    step_number: int,
    status:      str          # SUCCESS | SKIP
) -> None:
    """
    Write a success or skip event to the utilization table.
    Called on every successful step and every intentional skip.
    """
    item = {
        'event_id':    event_id,
        'lambda_step': f"{lambda_name}#{step_number}",
        'lambda_name': lambda_name,
        'step_number': step_number,
        'status':      status,
        'timestamp':   datetime.now(timezone.utc).isoformat()
    }
    try:
        _get_util_table().put_item(Item=item)
        logger.debug(json.dumps({
            "event":       "UTIL_WRITE",
            "event_id":    event_id,
            "lambda_name": lambda_name,
            "step_number": step_number,
            "status":      status
        }))
    except Exception as e:
        logger.error(json.dumps({
            "event":       "UTIL_TABLE_WRITE_ERROR",
            "event_id":    event_id,
            "lambda_name": lambda_name,
            "step_number": step_number,
            "error":       str(e)
        }))


def write_fault(
    event_id:     str,
    lambda_name:  str,
    step_number:  int,
    status:       str,         # FAILED | PERMANENT_FAILED | DLQ
    error_reason: str = ''
) -> None:
    """
    Write a failure event to the fault table.
    Called on every error path: transient failure, DLQ send, permanent failure.
    """
    item = {
        'event_id':     event_id,
        'lambda_step':  f"{lambda_name}#{step_number}",
        'lambda_name':  lambda_name,
        'step_number':  step_number,
        'status':       status,
        'error_reason': str(error_reason)[:500],
        'timestamp':    datetime.now(timezone.utc).isoformat()
    }
    try:
        _get_fault_table().put_item(Item=item)
        logger.debug(json.dumps({
            "event":        "FAULT_WRITE",
            "event_id":     event_id,
            "lambda_name":  lambda_name,
            "step_number":  step_number,
            "status":       status
        }))
    except Exception as e:
        logger.error(json.dumps({
            "event":       "FAULT_TABLE_WRITE_ERROR",
            "event_id":    event_id,
            "lambda_name": lambda_name,
            "step_number": step_number,
            "error":       str(e)
        }))
