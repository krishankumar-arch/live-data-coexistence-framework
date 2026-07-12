-- ═══════════════════════════════════════════════════════════════
-- LDCF POC — File 4/4: Keyring One-Time Load Script
-- Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
--
-- PURPOSE:
--   Run ONCE after DMS Task 1 (full load) completes.
--   Run BEFORE DMS Task 2 (CDC) starts.
--
--   Populates claim_keyring and policy_keyring from the
--   existing claim and policy records loaded by DMS Task 1.
--   PostgreSQL generates UUID automatically via gen_random_uuid().
--   UNIQUE constraint on legacy_*_num ensures idempotency —
--   safe to re-run if interrupted.
--
-- SEQUENCE:
--   Step 1: DMS Task 1 full load → COMPLETE
--   Step 2: Run this script         ← YOU ARE HERE
--   Step 3: DMS Task 2 CDC → START
-- ═══════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────
-- VERIFY full load counts before proceeding
-- ─────────────────────────────────────────────
DO $$
DECLARE
    v_policy_count  BIGINT;
    v_claim_count   BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_policy_count FROM insurance.policy;
    SELECT COUNT(*) INTO v_claim_count  FROM insurance.claim;

    IF v_policy_count = 0 THEN
        RAISE EXCEPTION 'insurance.policy is empty. Run DMS Task 1 first.';
    END IF;
    IF v_claim_count = 0 THEN
        RAISE EXCEPTION 'insurance.claim is empty. Run DMS Task 1 first.';
    END IF;

    RAISE NOTICE 'Pre-load check: % policies, % claims found. Proceeding.',
        v_policy_count, v_claim_count;
END $$;


-- ─────────────────────────────────────────────
-- POPULATE POLICY_KEYRING
-- One UUID per policy_num
-- gen_random_uuid() called by PostgreSQL DEFAULT
-- ON CONFLICT = idempotent (safe to re-run)
-- ─────────────────────────────────────────────
INSERT INTO insurance.policy_keyring
    (legacy_policy_num)
SELECT
    policy_num
FROM insurance.policy
ON CONFLICT (legacy_policy_num) DO NOTHING;

-- Log result
DO $$
DECLARE v_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_count FROM insurance.policy_keyring;
    RAISE NOTICE 'policy_keyring populated: % rows', v_count;
END $$;


-- ─────────────────────────────────────────────
-- POPULATE CLAIM_KEYRING
-- One UUID per claim_num
-- ON CONFLICT = idempotent (safe to re-run)
-- ─────────────────────────────────────────────
INSERT INTO insurance.claim_keyring
    (legacy_claim_num)
SELECT
    claim_num
FROM insurance.claim
ON CONFLICT (legacy_claim_num) DO NOTHING;

-- Log result
DO $$
DECLARE v_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_count FROM insurance.claim_keyring;
    RAISE NOTICE 'claim_keyring populated: % rows', v_count;
END $$;


-- ─────────────────────────────────────────────
-- FINAL VERIFICATION — counts must match
-- ─────────────────────────────────────────────
SELECT
    'policy'         AS table_name, COUNT(*) AS row_count FROM insurance.policy
UNION ALL SELECT
    'policy_keyring' AS table_name, COUNT(*) AS row_count FROM insurance.policy_keyring
UNION ALL SELECT
    'claim'          AS table_name, COUNT(*) AS row_count FROM insurance.claim
UNION ALL SELECT
    'claim_keyring'  AS table_name, COUNT(*) AS row_count FROM insurance.claim_keyring;
-- policy count must equal policy_keyring count
-- claim  count must equal claim_keyring count

-- Sample: verify UUIDs generated correctly
SELECT
    p.policy_num,
    pk.policy_uuid,
    pk.legacy_policy_num
FROM insurance.policy p
JOIN insurance.policy_keyring pk ON pk.legacy_policy_num = p.policy_num
LIMIT 3;
