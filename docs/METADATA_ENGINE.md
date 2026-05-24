# LDCF Metadata Transformation Engine

> How the metadata engine drives zero-hardcode dynamic DML generation.

---

## Overview

The metadata engine is the heart of LDCF Pattern 7. It stores all
source-to-target mapping rules in two database tables. The upstream loader
reads these rules at runtime and generates every SQL statement dynamically.

**No hardcoded table names. No hardcoded column names. No hardcoded SQL.**

When schemas change, only metadata_rules rows change — no code deployment.

---

## Three Metadata Tables

### connection_registry
Stores database connection details for every source and target.
Enables multi-source, multi-target routing without configuration changes.

```
connection_id | connection_name        | db_host          | db_type
1             | mysql-legacy-source    | mysql.xxxx.rds   | MYSQL
2             | aurora-cloud-target    | aurora.xxxx.rds  | POSTGRESQL
```

### metadata_map_master
One row per source→target table pair. One source table can have
multiple rows pointing to different target tables (1-to-many).

```
map_id | src_tbl  | dstn_tbl         | load_order | stream_type
1      | policy   | policy           | 1          | BOTH
2      | policy   | policy_keyring   | 2          | BOTH
3      | claim    | claim            | 1          | BOTH
4      | claim    | claim_keyring    | 2          | BOTH
```

### metadata_rules
One row per field mapping per target table. `column_order` maps
to CSV position (COLUMN5 = order 1, COLUMN6 = order 2, etc.).

```
rule_id | map_id | src_field    | dstn_field        | conversion_method | order
1       | 3      | claim_id     | legacy_claim_id   | LEGACY_REF        | 1
2       | 3      | claim_num    | claim_num         | DIRECT            | 2
3       | 3      | claim_amount | claim_amount      | NULL_TO_ZERO      | 6
4       | 4      | claim_num    | legacy_claim_num  | DIRECT            | 1
```

---

## Conversion Methods

| Method | Behaviour |
|--------|-----------|
| `DIRECT` | Copy value as-is |
| `NULL_TO_BLANK` | None/empty → `''` |
| `NULL_TO_ZERO` | None/empty → `0` |
| `NULL_TO_DATE` | None/empty → default date from `conversion_format_txt` |
| `LEGACY_REF` | Copy source PK/FK as legacy reference column |
| `UPPERCASE` | Apply `UPPER()` |
| `TRIM` | Apply `TRIM()` — removes whitespace and EBCDIC padding |
| `SKIP` | Exclude column from DML entirely |
| `UUID_GENERATE` | Column excluded — PostgreSQL `gen_random_uuid()` handles it |
| `SKIP_NULL_CONVERSION` | Keep string value as-is including literal string `"NULL"` |

---

## Dynamic DML Example

Given this metadata_rules for map_id=3 (claim → insurance.claim):

```
column_order=1: claim_id     → legacy_claim_id   LEGACY_REF
column_order=2: claim_num    → claim_num         DIRECT
column_order=5: claimant_name→ claimant_name     TRIM
column_order=6: claim_amount → claim_amount      NULL_TO_ZERO
```

The DML builder generates at runtime:

```sql
INSERT INTO insurance.claim
    (legacy_claim_id, claim_num, claimant_name, claim_amount)
VALUES
    (%s, %s, %s, %s)
ON CONFLICT (legacy_claim_id)
DO UPDATE SET
    claim_num     = EXCLUDED.claim_num,
    claimant_name = EXCLUDED.claimant_name,
    claim_amount  = EXCLUDED.claim_amount,
    last_modified = NOW()
```

With params: `[2000000, 'CLM-2024-0001', 'J. Smith', 5000.00]`

---

## Adding a New Table Mapping

No code change required. Insert rows only:

```sql
-- 1. Add map_master row
INSERT INTO metadata.metadata_map_master
    (src_connection_id, dstn_connection_id,
     src_schema_nam, dstn_schema_nam,
     src_tbl_nam, dstn_tbl_nam,
     src_pks, dstn_pks, load_order)
VALUES (1, 2, 'insurance', 'insurance',
        'new_table', 'new_cloud_table',
        'legacy_id', 'legacy_id', 1);

-- 2. Add rules for each field
INSERT INTO metadata.metadata_rules
    (map_id, src_field_name, dstn_field_name,
     conversion_method, column_order, ...)
VALUES ...;
```

The upstream loader's metadata cache refreshes on next cold start.
Force refresh by redeploying Lambda 2 or clearing the cache.
