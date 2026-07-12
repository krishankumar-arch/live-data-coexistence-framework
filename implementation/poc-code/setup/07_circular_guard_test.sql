-- ═══════════════════════════════════════════════════════════════
-- LDCF POC — Test Script 2: Circular Replication Guard Test
-- Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
--
-- RUN IN DBEAVER AGAINST MYSQL (insurance database)
-- PREREQUISITE: DMS CDC Task 2 must be running.
--
-- PURPOSE:
--   Tests LDCF Pattern 2 — Circular Replication Guard.
--
-- WHAT IT SIMULATES:
--   In a live bidirectional setup, Aurora writes data back to MySQL
--   stamped with datasync_flag='CLOUD'. DMS picks up these writes
--   as CDC events and forwards them to S3. Without the guard,
--   Lambda 2 would re-process them into Aurora — creating an
--   infinite replication loop.
--
--   This script simulates that scenario by directly inserting rows
--   with datasync_flag='CLOUD' into MySQL.
--
-- WHAT LAMBDA 2 MUST DO:
--   TX-CLOUD rows (datasync_flag='CLOUD' + operation=I):
--     → CIRCULAR_GUARD_SKIP logged in CloudWatch
--     → Row NOT inserted into Aurora
--
--   TX-NORMAL rows (datasync_flag=NULL):
--     → DML_SUCCESS logged in CloudWatch
--     → Row inserted into Aurora normally
--
-- EXPECTED AURORA RESULT:
--   insurance.policy:  POL-T2-NORMAL only (NOT POL-T2-CLOUD)
--   insurance.claim:   CLM-T2-NORMAL only (NOT CLM-T2-CLOUD)
--
-- HOW TO VERIFY:
--   CloudWatch → /aws/lambda/ldcf-poc-upstream-loader
--     Filter: CIRCULAR_GUARD_SKIP → Expected: 2 events (policy + claim CLOUD rows)
--     Filter: DML_SUCCESS          → Expected: 4+ events (normal rows only)
--
--   Aurora (run in DBeaver on Aurora connection):
--     SELECT policy_num, datasync_flag FROM insurance.policy
--     WHERE policy_num LIKE 'POL-T2-%';
--     → Expected: ONLY POL-T2-NORMAL (1 row). POL-T2-CLOUD must NOT appear.
--
--     SELECT claim_num, datasync_flag FROM insurance.claim
--     WHERE claim_num LIKE 'CLM-T2-%';
--     → Expected: ONLY CLM-T2-NORMAL (1 row). CLM-T2-CLOUD must NOT appear.
-- ═══════════════════════════════════════════════════════════════

USE insurance;

-- ─────────────────────────────────────────────────────────────
-- PRE-CHECK: confirm datasync_flag column exists in MySQL
-- ─────────────────────────────────────────────────────────────
SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_COMMENT
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'insurance'
  AND TABLE_NAME IN ('policy', 'claim')
  AND COLUMN_NAME = 'datasync_flag'
ORDER BY TABLE_NAME;
-- Expected: 2 rows — datasync_flag VARCHAR(10) NULL on both tables

-- ─────────────────────────────────────────────────────────────
-- TRANSACTION 1 (CLOUD): datasync_flag='CLOUD'
-- Simulates a row Aurora wrote back to MySQL (reverse sync).
-- DMS will capture this as CDC INSERT event.
-- Lambda 2 Pattern 2 MUST skip it — do NOT insert to Aurora.
-- ─────────────────────────────────────────────────────────────
START TRANSACTION;

INSERT INTO policy (
    policy_num,
    policy_holder_name,
    policy_type,
    effective_date,
    expiry_date,
    premium_amount,
    datasync_flag           -- ← THIS is what triggers Pattern 2
) VALUES (
    'POL-T2-CLOUD',
    'Cloud Sync Corporation',
    'HOME',
    '2026-01-01',
    '2027-01-01',
    9999.00,
    'CLOUD'                 -- ← Lambda 2 reads this and SKIPS the row
);

SET @cloud_pol_id  = LAST_INSERT_ID();
SET @cloud_pol_num = 'POL-T2-CLOUD';

INSERT INTO claim (
    claim_num, policy_id, policy_num,
    claimant_name, claim_amount, claim_status, incident_date,
    datasync_flag
) VALUES (
    'CLM-T2-CLOUD',
    @cloud_pol_id,
    @cloud_pol_num,
    'Cloud Claimant',
    9999.00,
    'OPEN',
    '2026-06-01',
    'CLOUD'                 -- ← Lambda 2 reads this and SKIPS the row
);

COMMIT;
-- DMS writes TX-CLOUD rows to S3 → Lambda 2 must log CIRCULAR_GUARD_SKIP
-- WAIT ~15 seconds before running TX-NORMAL below to get separate CSV files

SELECT 'TX-CLOUD SENT' AS status,
       policy_id, policy_num, datasync_flag
FROM policy WHERE policy_num = 'POL-T2-CLOUD';

-- ─────────────────────────────────────────────────────────────
-- PAUSE: wait 15-20 seconds here in DBeaver
-- This lets DMS flush the CLOUD transaction to S3 as a separate
-- file before the NORMAL transaction arrives. Separate CSV files
-- produce cleaner CloudWatch events for verification.
-- ─────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────
-- TRANSACTION 2 (NORMAL): datasync_flag=NULL (omitted)
-- Simulates a real legacy system write.
-- DMS captures this as a CDC INSERT event.
-- Lambda 2 Pattern 2 MUST process it — insert to Aurora.
-- ─────────────────────────────────────────────────────────────
START TRANSACTION;

INSERT INTO policy (
    policy_num,
    policy_holder_name,
    policy_type,
    effective_date,
    expiry_date,
    premium_amount
    -- datasync_flag omitted = NULL = legacy origin = SHOULD replicate
) VALUES (
    'POL-T2-NORMAL',
    'Normal Test Corp',
    'AUTO',
    '2026-01-01',
    '2027-01-01',
    1500.00
);

SET @normal_pol_id  = LAST_INSERT_ID();
SET @normal_pol_num = 'POL-T2-NORMAL';

INSERT INTO claim (
    claim_num, policy_id, policy_num,
    claimant_name, claim_amount, claim_status, incident_date
    -- datasync_flag omitted = NULL = SHOULD replicate
) VALUES (
    'CLM-T2-NORMAL',
    @normal_pol_id,
    @normal_pol_num,
    'Normal Claimant',
    2500.00,
    'OPEN',
    '2026-06-10'
);

COMMIT;
-- DMS writes TX-NORMAL rows to S3 → Lambda 2 must log DML_SUCCESS

SELECT 'TX-NORMAL SENT' AS status,
       policy_id, policy_num, datasync_flag
FROM policy WHERE policy_num = 'POL-T2-NORMAL';

-- ─────────────────────────────────────────────────────────────
-- WAIT ~30 seconds, then run verification queries on AURORA
-- ─────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────
-- AURORA VERIFICATION QUERIES
-- Run these in a separate DBeaver connection pointing to Aurora
-- ─────────────────────────────────────────────────────────────
/*

-- ── Must NOT exist (Pattern 2 blocked it) ───────────────────
SELECT 'CLOUD_ROW_IN_AURORA_BAD' AS result, COUNT(*) AS count
FROM insurance.policy
WHERE policy_num = 'POL-T2-CLOUD';
-- Expected: count = 0

SELECT 'CLOUD_CLAIM_IN_AURORA_BAD' AS result, COUNT(*) AS count
FROM insurance.claim
WHERE claim_num = 'CLM-T2-CLOUD';
-- Expected: count = 0

-- ── Must exist (normal row processed normally) ───────────────
SELECT 'NORMAL_ROW_IN_AURORA_GOOD' AS result,
       policy_id, policy_num, policy_holder_name, premium_amount
FROM insurance.policy
WHERE policy_num = 'POL-T2-NORMAL';
-- Expected: 1 row

SELECT 'NORMAL_CLAIM_IN_AURORA_GOOD' AS result,
       claim_id, claim_num, claimant_name, claim_amount
FROM insurance.claim
WHERE claim_num = 'CLM-T2-NORMAL';
-- Expected: 1 row

-- ── Keyring: UUID created for NORMAL only ───────────────────
SELECT 'KEYRING_CHECK' AS result,
       legacy_policy_num, CAST(policy_uuid AS TEXT) AS uuid
FROM insurance.policy_keyring
WHERE legacy_policy_num IN ('POL-T2-CLOUD', 'POL-T2-NORMAL');
-- Expected: 1 row (POL-T2-NORMAL only)

-- ── Pattern 2 summary ───────────────────────────────────────
SELECT
  (SELECT COUNT(*) FROM insurance.policy WHERE policy_num = 'POL-T2-CLOUD')   AS cloud_rows_blocked,
  (SELECT COUNT(*) FROM insurance.policy WHERE policy_num = 'POL-T2-NORMAL')  AS normal_rows_processed;
-- Expected: cloud_rows_blocked=0, normal_rows_processed=1

*/

-- ─────────────────────────────────────────────────────────────
-- CLOUDWATCH LOG VERIFICATION
-- ─────────────────────────────────────────────────────────────
/*
Go to:
  AWS Console → CloudWatch → Log Groups
  → /aws/lambda/ldcf-poc-upstream-loader
  → Search last 15 minutes

Query 1 — Pattern 2 skip events:
  filter event = "CIRCULAR_GUARD_SKIP"
  Expected: 2 events — one for policy (CLOUD), one for claim (CLOUD)
  Each log entry should show: datasync_flag=CLOUD, operation=I, reason=circular-guard

Query 2 — Normal processing:
  filter event = "DML_SUCCESS"
  Expected: 4+ events — policy + claim each going to 2 targets (main + keyring)

Query 3 — No errors:
  filter event = "DML_FAILED" or event = "NO_MAPPINGS"
  Expected: 0 matches
*/

-- ─────────────────────────────────────────────────────────────
-- CLEANUP (run in MySQL after verifying Aurora)
-- ─────────────────────────────────────────────────────────────
/*
-- MySQL cleanup
DELETE FROM claim  WHERE claim_num  IN ('CLM-T2-CLOUD', 'CLM-T2-NORMAL');
DELETE FROM policy WHERE policy_num IN ('POL-T2-CLOUD', 'POL-T2-NORMAL');

-- Aurora cleanup (run on Aurora connection in DBeaver)
DELETE FROM insurance.claim  WHERE claim_num  IN ('CLM-T2-CLOUD', 'CLM-T2-NORMAL');
DELETE FROM insurance.policy WHERE policy_num IN ('POL-T2-CLOUD', 'POL-T2-NORMAL');
DELETE FROM insurance.claim_keyring  WHERE legacy_claim_num  LIKE 'CLM-T2-%';
DELETE FROM insurance.policy_keyring WHERE legacy_policy_num LIKE 'POL-T2-%';
*/
