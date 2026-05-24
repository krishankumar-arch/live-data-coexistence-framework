# LDCF Architecture Overview

> Live Data Coexistence Framework — Five-Layer Architecture Narrative

---

## The Core Insight

Traditional migration approaches force a binary choice: **big-bang cutover**
(risky, requires downtime) or **phased migration** (slow, data gets stale).

LDCF introduces a third path: **coexistence**. Legacy and cloud systems run
simultaneously, share live data bidirectionally, and the cutover becomes a
business decision rather than a technical constraint.

---

## Five Layers

### Layer 1 — Physical Replication Pipeline

Captures every data change from the legacy source database and delivers it
to the cloud target within 60 seconds end-to-end.

**Components:** Qlik Replicate (mainframe/z-OS) or AWS DMS (relational databases)
→ pipe-separated CSV → Amazon S3 → Lambda 1 (Claim Check) → Amazon SQS

**Key design:** The Claim Check Pattern keeps SQS messages under 1KB regardless
of CSV file size by passing only the S3 file pointer — never the file content.

---

### Layer 2 — Integrity & Correctness Framework

Eight original patterns that ensure every replicated record is correct,
deduplicated, and traceable regardless of network conditions, retries,
or out-of-order delivery.

See [EIGHT_PATTERNS.md](EIGHT_PATTERNS.md) for full pattern descriptions.

---

### Layer 3 — Metadata Transformation Engine

Decouples the pipeline from any specific schema design. All INSERT, UPDATE,
and DELETE statements are generated dynamically at runtime from metadata rules.

**This enables:** One legacy table → multiple modern normalized target tables.
No code change required when schemas evolve — update metadata_rules rows only.

See [METADATA_ENGINE.md](../docs/METADATA_ENGINE.md) for full design.

---

### Layer 4 — Kafka Reverse Sync (Cloud → Legacy)

Enables cloud-native Domain APIs to write back to legacy systems during
coexistence. Domain events published to Kafka are consumed by a Spring Boot
listener that writes to legacy databases via JDBC Type 4.

**Circular loop prevention:** All cloud-originated writes carry
`datasync_flag = CLOUD`. Layer 2 Pattern 2 detects this flag and skips
replication — preventing infinite bidirectional loops.

---

### Layer 5 — Self-Healing Reconciliation

A daily AWS Glue job compares full table counts between source and target.
Any missing records trigger an SNS alert and are logged to an RDS audit table.
Failed events in DynamoDB can be reprocessed via Lambda — closed-loop recovery.

**Bounded drift guarantee:** No data drift goes undetected beyond 24 hours.

---

## Data Flow Summary

```
Legacy Insert/Update/Delete
        ↓ (< 60 seconds end-to-end)
DMS/Qlik captures change → CSV file → S3
        ↓
Lambda 1: S3 pointer → SQS (< 1KB message)
        ↓
Lambda 2: Fetch CSV → Apply 8 patterns → Dynamic DML → Aurora
        ↓                                              ↓
  DynamoDB audit                              Aurora updated
  (every event)
        ↓ (if failed, up to 3 retries via DLQ)
Lambda 4: DLQ → requeue → Lambda 2
        ↓ (after 3 failures)
PERMANENT_FAILED in DynamoDB → manual reprocess
        ↓ (daily)
Glue reconciliation → SNS alert → Lambda reprocess any drift
```
