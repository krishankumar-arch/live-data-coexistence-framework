-- ═══════════════════════════════════════════════════════════════
-- LDCF POC — Live Aurora Migration: Remove Legacy ID Columns
-- Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
--
-- PURPOSE:
--   Apply schema changes to a RUNNING Aurora instance that was
--   provisioned with 02_aurora_target_schema.sql BEFORE this
--   redesign.  Run this script INSTEAD of recreating the schema.
--
-- WHAT THIS DOES:
--   1. Drops legacy_policy_id / legacy_claim_id columns and their
--      unique constraints and indexes from all affected tables.
--   2. Restores the FK claim.policy_id → policy.policy_id
--      (the interim workaround pointed at legacy_policy_id).
--   3. Patches metadata seed data to reflect the new column names.
--
-- SAFE TO RUN:
--   All drops use IF EXISTS.  Metadata patches are idempotent UPDATEs.
--   Run inside a transaction — entire migration rolls back on error.
--
-- PREREQUISITE:
--   Stop or pause DMS CDC task before running.
--   Restart it after this script completes.
-- ═══════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────
-- STEP 1: insurance.policy — drop legacy_policy_id
-- ─────────────────────────────────────────────

-- Drop unique constraint on legacy_policy_id (may have been named differently)
ALTER TABLE insurance.policy DROP CONSTRAINT IF EXISTS uq_ins_legacy_pol_id;
ALTER TABLE insurance.policy DROP CONSTRAINT IF EXISTS uq_ins_policy_legacy_id;

-- Drop supporting index
DROP INDEX IF EXISTS insurance.idx_policy_legacy_id;

-- Drop the column
ALTER TABLE insurance.policy DROP COLUMN IF EXISTS legacy_policy_id;

-- ─────────────────────────────────────────────
-- STEP 2: insurance.claim — drop legacy_claim_id
--         and restore correct FK
-- ─────────────────────────────────────────────

-- Drop the interim FK workaround (references policy.legacy_policy_id)
ALTER TABLE insurance.claim DROP CONSTRAINT IF EXISTS fk_ins_claim_policy;

-- Drop unique constraint on legacy_claim_id
ALTER TABLE insurance.claim DROP CONSTRAINT IF EXISTS uq_ins_legacy_clm_id;
ALTER TABLE insurance.claim DROP CONSTRAINT IF EXISTS uq_ins_claim_legacy_id;

-- Drop supporting index
DROP INDEX IF EXISTS insurance.idx_claim_legacy_id;

-- Drop the column
ALTER TABLE insurance.claim DROP COLUMN IF EXISTS legacy_claim_id;

-- Restore FK: claim.policy_id → policy.policy_id
-- This is now correct because policy.policy_id stores the MySQL value directly.
ALTER TABLE insurance.claim
    ADD CONSTRAINT fk_ins_claim_policy
        FOREIGN KEY (policy_id)
        REFERENCES insurance.policy(policy_id)
        ON UPDATE CASCADE ON DELETE RESTRICT;

-- ─────────────────────────────────────────────
-- STEP 3: insurance.policy_keyring — drop legacy_policy_id
-- ─────────────────────────────────────────────

ALTER TABLE insurance.policy_keyring DROP CONSTRAINT IF EXISTS uq_policy_keyring_legacy_id;
ALTER TABLE insurance.policy_keyring DROP CONSTRAINT IF EXISTS uq_ins_policy_keyring_leg_id;
DROP INDEX IF EXISTS insurance.idx_policy_kr_legacy_id;
ALTER TABLE insurance.policy_keyring DROP COLUMN IF EXISTS legacy_policy_id;

-- ─────────────────────────────────────────────
-- STEP 4: insurance.claim_keyring — drop legacy_claim_id
-- ─────────────────────────────────────────────

ALTER TABLE insurance.claim_keyring DROP CONSTRAINT IF EXISTS uq_claim_keyring_legacy_id;
ALTER TABLE insurance.claim_keyring DROP CONSTRAINT IF EXISTS uq_ins_claim_keyring_leg_id;
DROP INDEX IF EXISTS insurance.idx_claim_kr_legacy_id;
ALTER TABLE insurance.claim_keyring DROP COLUMN IF EXISTS legacy_claim_id;

-- ─────────────────────────────────────────────
-- STEP 5: Patch metadata — map_master dstn_pks
-- Map 1: policy → insurance.policy
-- Map 3: claim  → insurance.claim
-- ─────────────────────────────────────────────

UPDATE metadata.metadata_map_master
   SET dstn_pks = 'policy_id',
       last_modified = NOW()
 WHERE map_id = 1;

UPDATE metadata.metadata_map_master
   SET dstn_pks = 'claim_id',
       last_modified = NOW()
 WHERE map_id = 3;

-- ─────────────────────────────────────────────
-- STEP 6: Patch metadata — rules
-- Map 1 rule: legacy_policy_id → policy_id
-- Map 3 rule: legacy_claim_id  → claim_id
-- ─────────────────────────────────────────────

UPDATE metadata.metadata_rules
   SET dstn_field_name = 'policy_id',
       last_modified = NOW()
 WHERE map_id = 1
   AND src_field_name = 'policy_id'
   AND dstn_field_name = 'legacy_policy_id';

UPDATE metadata.metadata_rules
   SET dstn_field_name = 'claim_id',
       last_modified = NOW()
 WHERE map_id = 3
   AND src_field_name = 'claim_id'
   AND dstn_field_name = 'legacy_claim_id';

-- ─────────────────────────────────────────────
-- STEP 7: Remove keyring rules that mapped to legacy ID columns
-- Map 2: remove policy_id → legacy_policy_id rule
-- Map 4: remove claim_id  → legacy_claim_id  rule
-- ─────────────────────────────────────────────

DELETE FROM metadata.metadata_rules
 WHERE map_id = 2
   AND src_field_name = 'policy_id'
   AND dstn_field_name = 'legacy_policy_id';

DELETE FROM metadata.metadata_rules
 WHERE map_id = 4
   AND src_field_name = 'claim_id'
   AND dstn_field_name = 'legacy_claim_id';

-- ─────────────────────────────────────────────
-- VERIFY — review before committing
-- ─────────────────────────────────────────────

-- Schema: check columns present / absent
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'insurance'
  AND table_name   = 'policy'
ORDER BY ordinal_position;
-- Expected: NO legacy_policy_id column

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'insurance'
  AND table_name   = 'claim'
ORDER BY ordinal_position;
-- Expected: NO legacy_claim_id column

-- FK check
SELECT tc.constraint_name, tc.table_name, kcu.column_name,
       ccu.table_name AS references_table, ccu.column_name AS references_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage ccu
    ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.table_schema = 'insurance';
-- Expected: fk_ins_claim_policy → policy(policy_id)

-- Metadata check
SELECT m.map_id, m.src_tbl_nam, m.dstn_tbl_nam, m.dstn_pks,
       COUNT(r.rule_id) AS rule_count
FROM metadata.metadata_map_master m
LEFT JOIN metadata.metadata_rules r ON m.map_id = r.map_id
GROUP BY m.map_id, m.src_tbl_nam, m.dstn_tbl_nam, m.dstn_pks
ORDER BY m.map_id;
-- Expected:
--   map_id=1  policy  → policy         dstn_pks=policy_id  10 rules
--   map_id=2  policy  → policy_keyring dstn_pks=legacy_policy_num  1 rule
--   map_id=3  claim   → claim          dstn_pks=claim_id   11 rules
--   map_id=4  claim   → claim_keyring  dstn_pks=legacy_claim_num   1 rule

COMMIT;
