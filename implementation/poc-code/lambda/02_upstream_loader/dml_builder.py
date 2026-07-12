"""
LDCF POC — Dynamic DML Builder
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
Pattern: Metadata-Driven Transformation (LDCF Pattern 7)

Builds parameterized SQL dynamically from metadata_rules.
NO hardcoded table names, column names, or SQL strings anywhere.
All SQL generated at runtime from metadata service response.

SUPPORTS:
  I (INSERT) → INSERT INTO ... ON CONFLICT DO UPDATE (upsert, Pattern 4)
  U (UPDATE) → same INSERT ... ON CONFLICT DO UPDATE
  D (DELETE) → DELETE FROM ... WHERE pk = %s

EXCLUDES from INSERT:
  UUID_GENERATE → PostgreSQL DEFAULT gen_random_uuid() handles this
  SKIP          → column excluded entirely
"""

import logging
from typing import Any, Dict, List, Optional, Tuple
from conversion_methods import apply_conversion

logger = logging.getLogger(__name__)

# Methods where column is excluded from INSERT — DB generates the value
DB_GENERATED = {'UUID_GENERATE', 'SKIP'}

# Source-side system fields used only by LDCF integrity patterns.
# These are read from the CSV into row_dict for pattern checks (e.g. Pattern 2
# Circular Replication Guard reads datasync_flag to decide whether to skip a row)
# but must NEVER be written to the target Aurora table.
# Add field names here to keep them available for pattern checks while
# excluding them from all generated INSERT / UPDATE / DELETE statements.
SYSTEM_ONLY_FIELDS = {'datasync_flag'}


def build_insert_upsert(
    mapping:    Dict,
    rules:      List[Dict],
    event_data: Dict
) -> Tuple[Optional[str], Optional[List]]:
    """
    Build parameterized INSERT ... ON CONFLICT DO UPDATE.
    Used for both I (INSERT) and U (UPDATE) operations.

    Args:
        mapping:    Row from metadata_map_master
        rules:      Rows from metadata_rules ordered by column_order
        event_data: Parsed CSV row as dict {src_field_name: value}

    Returns:
        (sql_string, params_list) or (None, None) if no columns
    """
    schema     = mapping['dstn_schema_nam']
    table      = mapping['dstn_tbl_nam']
    dstn_pks   = [pk.strip() for pk in mapping['dstn_pks'].split(',')]
    full_table = f"{schema}.{table}"

    columns = []
    params  = []

    for rule in sorted(rules, key=lambda r: r['column_order']):
        method   = (rule.get('conversion_method') or 'DIRECT').upper().strip()
        src_col  = rule['src_field_name']
        dst_col  = rule['dstn_field_name']
        fmt      = rule.get('conversion_format_txt')

        # Exclude DB-generated columns (UUID, SKIP)
        if method in DB_GENERATED:
            logger.debug(f"Excluding column {dst_col} (method={method})")
            continue

        # Exclude system-only fields used by LDCF pattern checks.
        # datasync_flag is read from the CSV for Pattern 2 Circular Guard
        # but must not be written to the target table.
        if src_col in SYSTEM_ONLY_FIELDS:
            logger.debug(f"Excluding system field {src_col} from target DML")
            continue

        raw_value   = event_data.get(src_col)
        transformed = apply_conversion(method, raw_value, fmt)

        columns.append(dst_col)
        params.append(transformed)

    if not columns:
        logger.warning(f"No columns produced for {full_table}")
        return None, None

    col_list      = ', '.join(columns)
    placeholders  = ', '.join(['%s'] * len(columns))
    conflict_cols = ', '.join(dstn_pks)

    # Build SET clause — update all non-PK columns using source values.
    # last_modified comes from the source row (via EXCLUDED) — do NOT
    # override it with NOW(). The source timestamp is the authoritative
    # last-write value for Pattern 3 (Last-Write-Wins).
    set_parts = [
        f"{col} = EXCLUDED.{col}"
        for col in columns
        if col not in dstn_pks
    ]
    set_clause = ', '.join(set_parts)

    sql = (
        f"INSERT INTO {full_table} ({col_list}) "
        f"VALUES ({placeholders}) "
        f"ON CONFLICT ({conflict_cols}) "
        f"DO UPDATE SET {set_clause}"
    )

    logger.debug(f"Generated UPSERT for {full_table}: "
                 f"{len(columns)} cols, conflict on ({conflict_cols})")
    return sql, params


def build_delete(
    mapping:    Dict,
    rules:      List[Dict],
    event_data: Dict
) -> Tuple[Optional[str], Optional[List]]:
    """
    Build parameterized DELETE FROM ... WHERE pk = %s.
    Uses dstn_pks from metadata_map_master to identify the record.
    Deleting a non-existent record returns 0 rows — treated as success
    (idempotent delete, Pattern 4).
    """
    schema     = mapping['dstn_schema_nam']
    table      = mapping['dstn_tbl_nam']
    dstn_pks   = [pk.strip() for pk in mapping['dstn_pks'].split(',')]
    full_table = f"{schema}.{table}"

    # Find the PK values from event_data using src_pks
    src_pks     = [pk.strip() for pk in mapping['src_pks'].split(',')]
    where_parts = []
    params      = []

    for src_pk, dst_pk in zip(src_pks, dstn_pks):
        # System-only fields are never valid PK columns — skip defensively
        if src_pk in SYSTEM_ONLY_FIELDS:
            logger.debug(f"Skipping system field {src_pk} in DELETE WHERE clause")
            continue

        # Find the rule for this PK field to apply correct conversion
        pk_rule = next(
            (r for r in rules if r['src_field_name'] == src_pk), None
        )
        method = (pk_rule.get('conversion_method') or 'DIRECT') if pk_rule else 'DIRECT'
        fmt    = pk_rule.get('conversion_format_txt') if pk_rule else None

        raw_value   = event_data.get(src_pk)
        transformed = apply_conversion(method, raw_value, fmt)

        where_parts.append(f"{dst_pk} = %s")
        params.append(transformed)

    if not where_parts:
        logger.warning(f"No PK values for DELETE on {full_table}")
        return None, None

    where_clause = ' AND '.join(where_parts)
    sql = f"DELETE FROM {full_table} WHERE {where_clause}"

    logger.debug(f"Generated DELETE for {full_table}: WHERE {where_clause}")
    return sql, params


def get_pk_values(mapping: Dict, event_data: Dict) -> Dict:
    """
    Extract source PK values from event_data for audit logging.
    Returns dict {pk_column: value} for DynamoDB event_data block.
    """
    src_pks = [pk.strip() for pk in mapping['src_pks'].split(',')]
    return {pk: event_data.get(pk) for pk in src_pks}
