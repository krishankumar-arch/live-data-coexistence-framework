"""
LDCF POC — Lambda 3: Metadata Service
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
Pattern: Metadata-Driven Transformation Engine (LDCF Layer 3)

INVOKED BY: Lambda 2 (synchronous RequestResponse call)
RESPONSIBILITY:
  Query Aurora metadata schema and return complete mapping definitions
  for a given source table. Response cached in Lambda 2 memory.

REQUEST:  {"src_schema": "insurance", "src_table": "claim"}
RESPONSE: {"mappings": [{...map_master + "rules": [...metadata_rules]}]}

PERFORMANCE:
  - Single query joining map_master and rules
  - Autocommit=True (read-only, no transaction overhead)
  - Connection reused across warm invocations
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

    if not src_table:
        logger.error(json.dumps({"event": "MISSING_SRC_TABLE"}))
        return {'mappings': [], 'error': 'src_table required'}

    logger.info(json.dumps({
        "event":      "METADATA_LOOKUP",
        "src_schema": src_schema,
        "src_table":  src_table
    }))

    try:
        conn     = _get_db_connection()
        mappings = _fetch_mappings(conn, src_schema, src_table)
        logger.info(json.dumps({
            "event":         "METADATA_FOUND",
            "src":           f"{src_schema}.{src_table}",
            "mapping_count": len(mappings)
        }))
        return {'mappings': mappings}
    except Exception as e:
        logger.error(json.dumps({"event": "METADATA_ERROR", "error": str(e)}))
        return {'mappings': [], 'error': str(e)}


def _fetch_mappings(conn, src_schema: str, src_table: str) -> List[Dict]:
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(MAPPINGS_SQL, (src_schema, src_table))
        mappings = [dict(row) for row in cur.fetchall()]

        if not mappings:
            logger.warning(json.dumps({
                "event": "NO_MAPPINGS",
                "src":   f"{src_schema}.{src_table}"
            }))
            return []

        for mapping in mappings:
            cur.execute(RULES_SQL, (mapping['map_id'],))
            mapping['rules'] = [dict(r) for r in cur.fetchall()]

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
    logger.info(json.dumps({"event": "DB_CONNECTED", "host": DB_HOST}))
    return _db_conn
