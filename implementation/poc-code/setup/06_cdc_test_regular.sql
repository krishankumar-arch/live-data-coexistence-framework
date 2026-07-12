-- ═══════════════════════════════════════════════════════════════
-- LDCF POC — Test Script 1: Regular CDC Pipeline Test
-- Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
--
-- RUN IN DBEAVER AGAINST MYSQL (insurance database)
-- PREREQUISITE: DMS CDC Task 2 must be running.
--
-- PURPOSE:
--   Verifies the end-to-end CDC pipeline for normal (non-cloud) rows.
--   Tests INSERT, UPDATE, and DELETE operations.
--   datasync_flag is NULL on all rows — Lambda 2 MUST process them.
--
-- PATTERN COVERAGE:
--   Pattern 1 — Dual-Sequence: MySQL generates EVEN IDs; Aurora keeps them
--   Pattern 4 — Upsert Tolerance: re-running INSERT updates via ON CONFLICT
--   Pattern 7 — 1-to-many: policy row → insurance.policy + policy_keyring
--   Pattern 8 — Independent DML: each operation is a separate transaction
--
-- EXPECTED AURORA RESULT after all transactions:
--   insurance.policy:         POL-T1-REGULAR row with updated premium=3200.00
--   insurance.claim:          CLM-T1-A row visible; CLM-T1-B row DELETED
--   insurance.policy_keyring: 1 UUID row for POL-T1-REGULAR
--   insurance.claim_keyring:  1 UUID row for CLM-T1-A
--
-- HOW TO VERIFY:
--   CloudWatch Log Group /aws/lambda/ldcf-poc-upstream-loader
--     → Filter: CIRCULAR_GUARD_SKIP  → Expected: 0 matches
--     → Filter: DML_SUCCESS           → Expected: matches per step below
--   Aurora (DBeaver):
--     SELECT * FROM insurance.policy  WHERE policy_num = 'POL-T1-REGULAR';
--     SELECT * FROM insurance.claim   WHERE policy_num = 'POL-T1-REGULAR';
--     SELECT * FROM insurance.policy_keyring WHERE legacy_policy_num = 'POL-T1-REGULAR';
-- ═══════════════════════════════════════════════════════════════

USE insurance;

-- ─────────────────────────────────────────────────────────────
-- STEP 1: INSERT — 1 policy + 2 claims in a single transaction
-- DMS PreserveTransactions=true → ONE CSV file for this commit
-- Expected DMS CSV: B + I(policy) + I(claim_A) + I(claim_B) + C
-- Expected Aurora:  3 rows inserted, 2 keyring UUIDs generated
-- ─────────────────────────────────────────────────────────────
START TRANSACTION;

INSERT INTO policy (
    policy_num,
    policy_holder_name,
    policy_type,
    effective_date,
    expiry_date,
    premium_amount
    -- datasync_flag intentionally omitted = NULL (legacy origin)
) VALUES (
    'POL-T1-REGULAR',
    'Regular Test Corp',
    'AUTO',
    '2026-01-01',
    '2027-01-01',
    2500.00
);

SET @pol_id  = LAST_INSERT_ID();
SET @pol_num = 'POL-T1-REGULAR';

INSERT INTO claim (
    claim_num, policy_id, policy_num,
    claimant_name, claim_amount, claim_status, incident_date
) VALUES (
    'CLM-T1-A', @pol_id, @pol_num,
    'Alice Regular', 5000.00, 'OPEN', '2026-06-01'
);

INSERT INTO claim (
    claim_num, policy_id, policy_num,
    claimant_name, claim_amount, claim_status, incident_date
) VALUES (
    'CLM-T1-B', @pol_id, @pol_num,
    'Bob Regular', 3000.00, 'OPEN', '2026-06-05'
);

COMMIT;

-- Verify MySQL INSERT
SELECT 'STEP1 POLICY' AS check_point,
       policy_id, policy_num, premium_amount, datasync_flag
FROM policy WHERE policy_num = 'POL-T1-REGULAR';

SELECT 'STEP1 CLAIMS' AS check_point,
       claim_id, claim_num, policy_id, claimant_name, claim_status
FROM claim WHERE policy_num = 'POL-T1-REGULAR';

-- ─────────────────────────────────────────────────────────────
-- STEP 2: UPDATE — change premium amount on the policy
-- Separate transaction → separate CSV file
-- Expected: Aurora policy row has premium_amount=3200.00
--           Pattern 3 (Last-Write-Wins) uses source last_modified
-- ─────────────────────────────────────────────────────────────
-- (pause ~5s so Lambda 2 finishes Step 1 before Step 2 arrives)

UPDATE policy
   SET premium_amount = 3200.00
 WHERE policy_num = 'POL-T1-REGULAR';

SELECT 'STEP2 UPDATE' AS check_point,
       policy_num, premium_amount, last_modified
FROM policy WHERE policy_num = 'POL-T1-REGULAR';

-- ─────────────────────────────────────────────────────────────
-- STEP 3: DELETE — remove CLM-T1-B claim
-- Separate transaction → separate CSV file
-- Expected: Aurora claim table has CLM-T1-A but NOT CLM-T1-B
-- ─────────────────────────────────────────────────────────────

DELETE FROM claim WHERE claim_num = 'CLM-T1-B';

SELECT 'STEP3 POST-DELETE MYSQL' AS check_point,
       claim_num, claimant_name, claim_status
FROM claim WHERE policy_num = 'POL-T1-REGULAR';
-- Expected: only CLM-T1-A remains in MySQL

-- ─────────────────────────────────────────────────────────────
-- FINAL VERIFICATION QUERIES
-- Run in DBeaver on Aurora (PostgreSQL connection)
-- ─────────────────────────────────────────────────────────────
/*
-- 1. Policy arrived and was updated
SELECT policy_id, policy_num, policy_holder_name,
       premium_amount, last_modified, datasync_flag
FROM insurance.policy
WHERE policy_num = 'POL-T1-REGULAR';
-- Expected: 1 row, premium_amount=3200.00

-- 2. Only CLM-T1-A exists (CLM-T1-B was deleted)
SELECT claim_id, claim_num, claimant_name, claim_status
FROM insurance.claim
WHERE policy_num = 'POL-T1-REGULAR';
-- Expected: 1 row (CLM-T1-A only)

-- 3. Keyring UUIDs were created for policy + claim
SELECT 'policy_keyring' AS t, legacy_policy_num, CAST(policy_uuid AS TEXT)
FROM insurance.policy_keyring
WHERE legacy_policy_num = 'POL-T1-REGULAR'
UNION ALL
SELECT 'claim_keyring', legacy_claim_num, CAST(claim_uuid AS TEXT)
FROM insurance.claim_keyring
WHERE legacy_claim_num = 'CLM-T1-A';
-- Expected: 2 rows, each with a valid UUID

-- 4. DynamoDB audit — check for SUCCESS events
-- AWS Console → DynamoDB → ldcf-poc-utilization-log → Items
-- Filter: event_id contains 'T1' or filter by timestamp
*/

-- ─────────────────────────────────────────────────────────────
-- CLEANUP (run after verifying Aurora, before next test)
-- ─────────────────────────────────────────────────────────────
/*
DELETE FROM claim  WHERE policy_num = 'POL-T1-REGULAR';
DELETE FROM policy WHERE policy_num = 'POL-T1-REGULAR';
-- Also clean Aurora after:
-- DELETE FROM insurance.claim  WHERE policy_num = 'POL-T1-REGULAR';
-- DELETE FROM insurance.policy WHERE policy_num = 'POL-T1-REGULAR';
-- DELETE FROM insurance.claim_keyring  WHERE legacy_claim_num  LIKE 'CLM-T1-%';
-- DELETE FROM insurance.policy_keyring WHERE legacy_policy_num = 'POL-T1-REGULAR';
*/
