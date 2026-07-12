-- ═══════════════════════════════════════════════════════════════
-- LDCF POC — File 6: CDC Test Transaction (MySQL Legacy Source)
-- Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
--
-- RUN THIS IN DBEAVER AGAINST MYSQL (insurance database)
-- AFTER the DMS CDC task (Task 2) is running.
--
-- PURPOSE:
--   Inserts 1 new policy + 2 new claims in a SINGLE TRANSACTION.
--   DMS CDC with PreserveTransactions=true writes ONE CSV file
--   for the entire commit containing rows from BOTH tables.
--
-- EXPECTED CSV FILE in S3 (dms/sync/CDC_TXN_<timestamp>.csv):
--   B                                              <- Begin marker
--   I|policy|insurance|ts|policy_id|..data..|      <- INSERT policy
--   I|claim|insurance|ts|claim_id|..data..|        <- INSERT claim 1
--   I|claim|insurance|ts|claim_id|..data..|        <- INSERT claim 2
--   C                                              <- Commit marker
--
-- DMS PreserveTransactions=true CSV layout per data row:
--   pos 0 = op (I/U/D)
--   pos 1 = table_name  (DMS auto-prepends)
--   pos 2 = schema_name (DMS auto-prepends)
--   pos 3 = event_ts    (S3 endpoint TimestampColumnName)
--   pos 4+ = MySQL data columns in schema definition order
--
-- This proves:
--   1. Multi-table transaction lands in ONE file
--   2. B/C markers are present (Lambda 2 must skip them)
--   3. table and schema appear at FIXED positions 1 and 2 (not at end)
-- ═══════════════════════════════════════════════════════════════

USE insurance;

START TRANSACTION;

-- ── Insert 1 new policy ───────────────────────────────────────
INSERT INTO policy (
    policy_num,
    policy_holder_name,
    policy_type,
    effective_date,
    expiry_date,
    premium_amount
) VALUES (
    'POL-2026-TEST01',
    'CDC Test Corporation',
    'AUTO',
    '2026-01-01',
    '2027-01-01',
    2500.00
);

-- Capture the generated policy_id for claim FK references
SET @new_policy_id  = LAST_INSERT_ID();
SET @new_policy_num = 'POL-2026-TEST01';

-- ── Insert 2 claims against the new policy ───────────────────
INSERT INTO claim (
    claim_num,
    policy_id,
    policy_num,
    claimant_name,
    claim_amount,
    claim_status,
    incident_date
) VALUES (
    'CLM-2026-TEST01',
    @new_policy_id,
    @new_policy_num,
    'Test Claimant A',
    7500.00,
    'OPEN',
    '2026-06-01'
);

INSERT INTO claim (
    claim_num,
    policy_id,
    policy_num,
    claimant_name,
    claim_amount,
    claim_status,
    incident_date
) VALUES (
    'CLM-2026-TEST02',
    @new_policy_id,
    @new_policy_num,
    'Test Claimant B',
    3200.00,
    'UNDER_REVIEW',
    '2026-06-10'
);

COMMIT;

-- ── Verify rows inserted ──────────────────────────────────────
SELECT 'POLICY' AS tbl, policy_id, policy_num, policy_holder_name, policy_type
FROM   policy
WHERE  policy_num = 'POL-2026-TEST01';

SELECT 'CLAIM' AS tbl, claim_id, claim_num, policy_id, claimant_name, claim_amount, claim_status
FROM   claim
WHERE  policy_id = @new_policy_id;

-- ── What to check after running ──────────────────────────────
-- 1. S3 bucket → dms/sync/ → look for CDC_TXN_<timestamp>.csv
--    File should contain 5 lines: B + 3 data rows + C
--
-- 2. DynamoDB ldcf-poc-utilization-log → should show
--    PROCESSING_SUCCESS entries for the claim and policy rows
--
-- 3. Aurora insurance.policy and insurance.claim → new rows
--    matching the MySQL inserts above
