"""
LDCF POC — Conversion Methods
Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
Pattern: Metadata-Driven Transformation (LDCF Pattern 7)

Applies conversion_method and conversion_format_txt from metadata_rules
to transform source field values before DML execution.

Each method is a pure function — no side effects, no DB calls.
  Input:  raw string value from CSV + optional format string
  Output: transformed Python value safe for psycopg2 parameterized query

CONVERSION_METHOD values:
  DIRECT              — copy value as-is
  NULL_TO_BLANK       — None/empty → ''
  NULL_TO_ZERO        — None/empty → 0
  NULL_TO_DATE        — None/empty → default date (from conversion_format_txt)
  LEGACY_REF          — copy source PK/FK as legacy reference column
  UPPERCASE           — apply UPPER()
  TRIM                — apply TRIM()
  SKIP                — exclude column from DML entirely
  UUID_GENERATE       — column excluded; PostgreSQL DEFAULT gen_random_uuid()
  SKIP_NULL_CONVERSION — keep string value as-is including string "NULL"
"""

import logging
from datetime import date, datetime
from typing import Any, Optional

logger = logging.getLogger(__name__)


def apply_conversion(method: str, value: Any,
                     fmt: Optional[str] = None) -> Any:
    """
    Central dispatcher. Routes to correct conversion function.
    Called by dml_builder for every field in every CSV row.

    Args:
        method: conversion_method from metadata_rules
        value:  raw value from parsed CSV row (always a string from CSV)
        fmt:    conversion_format_txt from metadata_rules (optional)

    Returns:
        Transformed Python value for psycopg2 parameterized query
    """
    m = (method or 'DIRECT').upper().strip()

    # SKIP and UUID_GENERATE are handled by dml_builder
    # (column excluded from INSERT entirely)
    # Included here for completeness but dml_builder checks first
    if m in ('SKIP', 'UUID_GENERATE'):
        return None

    dispatch = {
        'DIRECT':               _direct,
        'NULL_TO_BLANK':        _null_to_blank,
        'NULL_TO_ZERO':         _null_to_zero,
        'NULL_TO_DATE':         _null_to_date,
        'LEGACY_REF':           _legacy_ref,
        'UPPERCASE':            _uppercase,
        'TRIM':                 _trim,
        'SKIP_NULL_CONVERSION': _skip_null_conversion,
    }

    func = dispatch.get(m, _direct)
    return func(value, fmt)


# ─────────────────────────────────────────────
# Conversion implementations
# ─────────────────────────────────────────────

def _direct(value: Any, fmt: Optional[str] = None) -> Any:
    """Copy value as-is. Empty string stays empty. None stays None."""
    if value == '' or value == 'NULL':
        return None
    return value


def _null_to_blank(value: Any, fmt: Optional[str] = None) -> str:
    """None/empty/NULL string → empty string ''."""
    if value is None or str(value).strip() in ('', 'NULL'):
        return ''
    return str(value)


def _null_to_zero(value: Any, fmt: Optional[str] = None):
    """None/empty/NULL → 0. Preserves decimal precision."""
    if value is None or str(value).strip() in ('', 'NULL'):
        return 0
    try:
        return float(value)
    except (ValueError, TypeError):
        logger.warning(f"NULL_TO_ZERO: cannot convert '{value}' to number, using 0")
        return 0


def _null_to_date(value: Any, fmt: Optional[str] = None) -> Optional[date]:
    """
    None/empty/NULL → default date from conversion_format_txt.
    Falls back to 1900-01-01 if format not provided.
    """
    if value is None or str(value).strip() in ('', 'NULL'):
        default_str = fmt or '1900-01-01'
        try:
            parts = default_str.split('-')
            return date(int(parts[0]), int(parts[1]), int(parts[2]))
        except Exception:
            return date(1900, 1, 1)
    return value


def _legacy_ref(value: Any, fmt: Optional[str] = None) -> Any:
    """
    Copy source PK/FK as legacy reference column.
    Used for claim_id → legacy_claim_id, policy_id → legacy_policy_id.
    Passes value through unchanged — preserves integer type.
    """
    if value is None or str(value).strip() in ('', 'NULL'):
        return None
    try:
        return int(value)
    except (ValueError, TypeError):
        return value


def _uppercase(value: Any, fmt: Optional[str] = None) -> Optional[str]:
    """Apply UPPER(). Used for status codes, policy types."""
    if value is None or str(value).strip() in ('', 'NULL'):
        return None
    return str(value).upper()


def _trim(value: Any, fmt: Optional[str] = None) -> Optional[str]:
    """
    Apply TRIM(). Removes whitespace and EBCDIC padding artifacts.
    Used for name fields from mainframe/legacy sources.
    """
    if value is None or str(value).strip() in ('', 'NULL'):
        return None
    return str(value).strip()


def _skip_null_conversion(value: Any, fmt: Optional[str] = None) -> Any:
    """
    Keep value exactly as it comes from CSV — including string 'NULL'.
    Used when legacy system deliberately stores the string 'NULL'
    as a sentinel value distinct from database NULL.
    Do NOT convert to Python None / database NULL.
    """
    return value  # pass through completely unchanged
