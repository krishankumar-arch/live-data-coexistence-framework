"""
LDCF POC -- Lambda 3: Metadata Service
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
Pattern: Metadata-Driven Transformation Engine (LDCF Layer 3)

INVOKED BY: Lambda 2 (synchronous RequestResponse call)
RESPONSIBILITY:
  Query Aurora metadata schema and return complete mapping definitions
  for a given source table. Response cached in Lambda 2 memory.

REQUEST:  {"src_schema": "insurance", "src_table": "claim"}
RESPONSE: {"mappings": [{...map_master + "rules": [...metadata_rules]}]}

STEPS (for utilization/fault table writes):
  Step 1 -- Mapping query executed
  Step 2 -- Rules fetched, response returned

PERFORMANCE:
  - Single query joining map_master and rules
  - Autocommit=True (read-only, no transaction overhead)
  - Connection reused across warm invocations

ENVIRONMENT VARIABLES:
  DB_SECRET_ARN        -- Secrets Manager ARN for Aurora credentials
  DB_HOST              -- Aurora endpoint
  DB_PORT              -- Aurora port (default 5432)
  DB_NAME              -- Database name (default ldcfdb)
  DYNAMODB_FAULT_TABLE -- fault table name (Lambda 3 writes faults only)
"""

import os
import json
import logging
import psycopg2
import psycopg2.extras
import boto3
from typing import Any, Dict, List

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets = boto3.client('secretsmanager')

DB_SECRET_ARN = os.environ['DB_SECRET_ARN']
DB_HOST       = os.environ['DB_HOST']
DB_PORT       = int(os.environ.get('DB_PORT', '5432'))
DB_NAME       = os.environ.get('DB_NAME', 'ldcfdb')
FUNCTION_NAME = os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'ldcf-poc-metadata-service')

from dynamo_writer import write_fault

_db_conn = None  # reused across warm invocations

MAPPINGS_SQL = """
    SELECT
        m.map_id, m.src_connection_id, m.dstn_connection_id,
        m.src_schema_nam, m.dstn_schema_nam,
        m.src_tbl_nam, m.dstn_tbl_nam,
        m.src_pks, m.dstn_pks,
        m.is_active, m.stream_type, m.load_order,
        c.db_host AS dstn_db_host,
        c.db_port AS dstn_db_port,
        c.db_name AS dstn_db_name,
        c.db_secret_arn AS dstn_secret_arn
    FROM   metadata.metadata_map_master m
    JOIN   metadata.connection_registry  c ON c.connection_id = m.dstn_connection_id
    WHERE  m.src_schema_nam = %s
      AND  m.src_tbl_nam    = %s
      AND  m.is_active      = true
    ORDER  BY m.load_order ASC
"""

RULES_SQL = """
    SELECT
        rule_id, map_id,
        src_field_name, src_datatype_txt,
        dstn_field_name, dstn_datatype_txt,
        conversion_method, conversion_format_txt,
        column_order, created_by
    FROM  metadata.metadata_rules
    WHERE map_id = %s
    ORDER BY column_order ASC
"""


def handler(event, context):
    """Return active mappings and rules for a source table."""
    src_schema = event.get('src_schema', 'insurance')
    src_table  = event.get('src_table')
    # Use src as a pseudo-identifier for fault logging (no event_id at this layer)
    pseudo_id  = f"{src_schema}.{src_table}"

    if not src_table:
        logger.error(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "MISSING_SRC_TABLE",
            "step":          1
        }))
        return {'mappings': [], 'error': 'src_table required'}

    logger.info(json.dumps({
        "function_name": FUNCTION_NAME,
        "event":         "METADATA_LOOKUP",
        "step":          1,
        "src_schema":    src_schema,
        "src_table":     src_table
    }))

    try:
        conn     = _get_db_connection()
        mappings = _fetch_mappings(conn, src_schema, src_table)

        logger.info(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "METADATA_FOUND",
            "step":          2,
            "src":           pseudo_id,
            "mapping_count": len(mappings)
        }))
        return {'mappings': mappings}

    except Exception as e:
        logger.error(json.dumps({
            "function_name": FUNCTION_NAME,
            "event":         "METADATA_ERROR",
            "step":          1,
            "src":           pseudo_id,
            "error":         str(e)
        }))
        write_fault(
            event_id=pseudo_id,
            lambda_name=FUNCTION_NAME,
            step_number=1,
            status='FAILED',
            error_reason=str(e)
        )
        return {'mappings': [], 'error': str(e)}


def _fetch_mappings(conn, src_schema: str, src_table: str) -> List[Dict]:
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(MAPPINGS_SQL, (src_schema, src_table))
        mappings = [dict(row) for row in cur.fetchall()]

        if not mappings:
            logger.warning(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "NO_MAPPINGS_IN_DB",
                "step":          1,
                "src":           f"{src_schema}.{src_table}",
                "message":       "No active rows in metadata_map_master for this source"
            }))
            return []

        for mapping in mappings:
            cur.execute(RULES_SQL, (mapping['map_id'],))
            mapping['rules'] = [dict(r) for r in cur.fetchall()]
            logger.info(json.dumps({
                "function_name": FUNCTION_NAME,
                "event":         "RULES_FETCHED",
                "step":          2,
                "map_id":        mapping['map_id'],
                "rule_count":    len(mapping['rules'])
            }))

    return mappings


def _get_db_connection():
    global _db_conn
    try:
        if _db_conn and not _db_conn.closed:
            _db_conn.cursor().execute('SELECT 1')
            return _db_conn
    except Exception:
        _db_conn = None

    secret = json.loads(
        secrets.get_secret_value(SecretId=DB_SECRET_ARN)['SecretString']
    )
    _db_conn = psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=secret['username'], password=secret['password'],
        connect_timeout=10,
        options='-c search_path=metadata,insurance,public'
    )
    _db_conn.autocommit = True  # read-only
    logger.info(json.dumps({
        "function_name": FUNCTION_NAME,
        "event":         "DB_CONNECTED",
        "host":          DB_HOST
    }))
    return _db_conn
