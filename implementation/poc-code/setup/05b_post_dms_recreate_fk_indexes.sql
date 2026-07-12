-- ═══════════════════════════════════════════════════════════════
-- LDCF POC — File 5b: Post-DMS Full Load — Recreate FK & Indexes
-- Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
--
-- RUN THIS IN DBEAVER AGAINST AURORA POSTGRESQL (ldcfdb)
-- AFTER the DMS full load task completes with TablesLoaded=2.
--
-- WHY:
--   Restores all FK constraints and non-unique indexes that were
--   dropped by 05a_pre_dms_drop_fk_indexes.sql before the load.
--
-- SAFE TO RUN MULTIPLE TIMES: All statements use IF NOT EXISTS
-- or "DROP ... IF EXISTS" before recreating.
--
-- ORDER MATTERS for FKs:
--   insurance.policy must be fully loaded before adding the FK
--   on insurance.claim that references it. Since we only run
--   this AFTER DMS completes, both tables are already populated.
-- ═══════════════════════════════════════════════════════════════

\echo '── Post-DMS: recreating FK and indexes on insurance schema ──'

-- ─────────────────────────────────────────────
-- 1. Quick sanity check — confirm data landed
-- ─────────────────────────────────────────────
\echo ''
\echo '── Row counts (must be > 0 before continuing) ──'
SELECT 'insurance.policy' AS tbl, COUNT(*) AS rows FROM insurance.policy
UNION ALL
SELECT 'insurance.claim'  AS tbl, COUNT(*) AS rows FROM insurance.claim;

-- ─────────────────────────────────────────────
-- 2. Recreate FK: insurance.claim → insurance.policy
--    Drops first so script is idempotent.
-- ─────────────────────────────────────────────
ALTER TABLE insurance.claim
    DROP CONSTRAINT IF EXISTS fk_ins_claim_policy;

ALTER TABLE insurance.claim
    ADD CONSTRAINT fk_ins_claim_policy
        FOREIGN KEY (policy_id)
        REFERENCES insurance.policy (policy_id)
        ON UPDATE CASCADE
        ON DELETE RESTRICT;

\echo 'Recreated: fk_ins_claim_policy'

-- ─────────────────────────────────────────────
-- 3. Recreate keyring indexes
-- (legacy_policy_id / legacy_claim_id columns removed in schema
--  redesign — those indexes no longer exist. Only keyring num
--  indexes are recreated here.)
-- ─────────────────────────────────────────────
DROP INDEX IF EXISTS insurance.idx_claim_kr_legacy_num;
CREATE INDEX idx_claim_kr_legacy_num
    ON insurance.claim_keyring (legacy_claim_num);

DROP INDEX IF EXISTS insurance.idx_policy_kr_legacy_num;
CREATE INDEX idx_policy_kr_legacy_num
    ON insurance.policy_keyring (legacy_policy_num);

\echo 'Recreated: idx_claim_kr_legacy_num, idx_policy_kr_legacy_num'

-- ─────────────────────────────────────────────
-- 4. Update table statistics so the planner
--    has accurate estimates after bulk load
-- ─────────────────────────────────────────────
ANALYZE insurance.policy;
ANALYZE insurance.claim;

\echo 'ANALYZE complete on policy and claim'

-- ─────────────────────────────────────────────
-- 5. Final verification
-- ─────────────────────────────────────────────
\echo ''
\echo '── Verification: FK constraints on insurance.claim ──'
SELECT conname,
       contype,
       pg_get_constraintdef(oid) AS definition
FROM   pg_constraint
WHERE  conrelid = 'insurance.claim'::regclass
ORDER  BY contype, conname;

\echo ''
\echo '── Verification: all indexes on insurance schema ──'
SELECT tablename,
       indexname,
       indexdef
FROM   pg_indexes
WHERE  schemaname = 'insurance'
ORDER  BY tablename, indexname;

\echo ''
\echo '── Final row counts ──'
SELECT 'insurance.policy' AS tbl, COUNT(*) AS rows FROM insurance.policy
UNION ALL
SELECT 'insurance.claim'  AS tbl, COUNT(*) AS rows FROM insurance.claim;

\echo ''
\echo '✓ Post-DMS restore complete.'
\echo '  You may now start the CDC task (DMS Task 2).'
\echo '  Next step: run 04_keyring_oneshot_load.sql'
