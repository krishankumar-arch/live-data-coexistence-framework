-- ═══════════════════════════════════════════════════════════════
-- LDCF POC — File 5a: Pre-DMS Full Load — Drop FK & Indexes
-- Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
--
-- RUN THIS IN DBEAVER AGAINST AURORA POSTGRESQL (ldcfdb)
-- BEFORE starting the DMS full load task.
--
-- WHY:
--   DMS full load issues TRUNCATE on each target table.
--   PostgreSQL blocks TRUNCATE on any table referenced by a FK
--   even when the referencing table is empty:
--     "cannot truncate a table referenced in a foreign key constraint"
--   Dropping the FK before the load lets TRUNCATE + INSERT run freely.
--
--   Non-unique indexes on large tables also slow bulk INSERT significantly.
--   Dropping them before load and rebuilding after is standard practice.
--
-- AFTER DMS FULL LOAD COMPLETES:
--   Run 05b_post_dms_recreate_fk_indexes.sql to restore all constraints.
--
-- SAFE TO RUN MULTIPLE TIMES: All statements use IF EXISTS.
-- ═══════════════════════════════════════════════════════════════

\echo '── Pre-DMS: dropping FK and non-unique indexes on insurance schema ──'

-- ─────────────────────────────────────────────
-- 1. Drop FK constraint
--    insurance.claim → insurance.policy(policy_id)
-- ─────────────────────────────────────────────
ALTER TABLE insurance.claim
    DROP CONSTRAINT IF EXISTS fk_ins_claim_policy;

\echo 'Dropped: fk_ins_claim_policy'

-- ─────────────────────────────────────────────
-- 2. Drop non-unique indexes on insurance.claim
-- ─────────────────────────────────────────────
DROP INDEX IF EXISTS insurance.idx_claim_legacy_id;

\echo 'Dropped: idx_claim_legacy_id'

-- ─────────────────────────────────────────────
-- 3. Drop non-unique indexes on insurance.policy
-- ─────────────────────────────────────────────
DROP INDEX IF EXISTS insurance.idx_policy_legacy_id;

\echo 'Dropped: idx_policy_legacy_id'

-- ─────────────────────────────────────────────
-- 4. Drop non-unique indexes on keyring tables
--    (not loaded by DMS but drop for consistency)
-- ─────────────────────────────────────────────
DROP INDEX IF EXISTS insurance.idx_claim_kr_legacy_num;
DROP INDEX IF EXISTS insurance.idx_policy_kr_legacy_num;

\echo 'Dropped: idx_claim_kr_legacy_num, idx_policy_kr_legacy_num'

-- ─────────────────────────────────────────────
-- 5. Verify — should return 0 rows for the
--    items we just dropped
-- ─────────────────────────────────────────────
\echo ''
\echo '── Verification: remaining constraints on insurance.claim ──'
SELECT conname, contype, pg_get_constraintdef(oid) AS definition
FROM   pg_constraint
WHERE  conrelid = 'insurance.claim'::regclass
ORDER  BY contype, conname;

\echo ''
\echo '── Verification: remaining non-unique indexes on insurance schema ──'
SELECT schemaname, tablename, indexname, indexdef
FROM   pg_indexes
WHERE  schemaname = 'insurance'
  AND  indexname NOT IN (
         -- exclude primary keys and unique indexes (kept intact)
         SELECT conname FROM pg_constraint
         WHERE  conrelid IN (
                    'insurance.policy'::regclass,
                    'insurance.claim'::regclass
                )
           AND  contype IN ('p','u')
       )
ORDER  BY tablename, indexname;

\echo ''
\echo '✓ Pre-DMS prep complete. You may now start the DMS full load task.'
\echo '  After load completes run: 05b_post_dms_recreate_fk_indexes.sql'
