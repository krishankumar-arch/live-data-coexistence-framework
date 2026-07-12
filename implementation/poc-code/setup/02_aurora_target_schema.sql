-- ═══════════════════════════════════════════════════════════════
-- LDCF POC — File 2/4: Cloud Target Schema (Aurora PostgreSQL)
-- Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
--
-- SCHEMAS CREATED:
--   insurance  — business tables (claim, policy, keyrings)
--   metadata   — mapping engine (connection_registry, map_master, rules)
--
-- PATTERN 1: ODD sequences = cloud-generated records
--   policy_id / claim_id use ODD sequences so cloud-native records
--   never collide with MySQL-originated EVEN auto_increment IDs.
--   When the legacy system passes its own id (e.g. policy_id=1000026),
--   that value is stored directly — sequence is only used for new
--   cloud-originated records that have no legacy counterpart.
--
-- PATTERN 7: gen_random_uuid() for PII tokenization
--            UNIQUE on legacy_*_num = idempotency guard on keyring tables
-- ═══════════════════════════════════════════════════════════════

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─────────────────────────────────────────────
-- SCHEMAS
-- ─────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS insurance;
CREATE SCHEMA IF NOT EXISTS metadata;

-- ─────────────────────────────────────────────
-- SEQUENCES — ODD numbers only (Pattern 1)
-- Used only when no id is supplied by the caller.
-- MySQL auto_increment generates EVEN numbers so
-- cloud-originated records (ODD) never collide.
-- ─────────────────────────────────────────────
CREATE SEQUENCE IF NOT EXISTS insurance.policy_id_seq        INCREMENT 2 START 1000001 MINVALUE 1;
CREATE SEQUENCE IF NOT EXISTS insurance.claim_id_seq         INCREMENT 2 START 2000001 MINVALUE 1;
CREATE SEQUENCE IF NOT EXISTS insurance.claim_keyring_id_seq INCREMENT 2 START 3000001 MINVALUE 1;
CREATE SEQUENCE IF NOT EXISTS insurance.policy_keyring_id_seq INCREMENT 2 START 4000001 MINVALUE 1;
CREATE SEQUENCE IF NOT EXISTS metadata.map_id_seq            INCREMENT 1 START 1;
CREATE SEQUENCE IF NOT EXISTS metadata.rule_id_seq           INCREMENT 1 START 1;
CREATE SEQUENCE IF NOT EXISTS metadata.conn_id_seq           INCREMENT 1 START 1;

-- ─────────────────────────────────────────────
-- INSURANCE.POLICY
-- policy_id accepts the MySQL value when supplied by the legacy system
-- (e.g. policy_id=1000026 from DMS CDC).  When no value is provided
-- (cloud-native record), DEFAULT nextval generates the next ODD id.
-- No separate legacy_policy_id column is needed — policy_id IS the
-- single identity for both cloud and legacy records.
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS insurance.policy (
    policy_id           BIGINT          NOT NULL DEFAULT nextval('insurance.policy_id_seq'),
    policy_num          VARCHAR(50)     NOT NULL,
    policy_holder_name  VARCHAR(200)    NOT NULL,
    policy_type         VARCHAR(50)     NOT NULL,
    effective_date      DATE            NOT NULL,
    expiry_date         DATE            NOT NULL,
    premium_amount      NUMERIC(12,2)   NOT NULL DEFAULT 0.00,
    created_at          TIMESTAMP       NOT NULL DEFAULT NOW(),
    last_modified       TIMESTAMP       NOT NULL DEFAULT NOW(),
    datasync_flag       VARCHAR(10)     NULL,
    CONSTRAINT pk_ins_policy         PRIMARY KEY (policy_id),
    CONSTRAINT uq_ins_policy_num     UNIQUE (policy_num)
);
COMMENT ON TABLE  insurance.policy IS 'Cloud policy. ODD policy_id = cloud origin; EVEN policy_id = legacy origin (LDCF Pattern 1).';
COMMENT ON COLUMN insurance.policy.policy_id IS
    'Unified PK. MySQL supplies EVEN values via CDC; cloud generates ODD values via sequence.';

-- ─────────────────────────────────────────────
-- INSURANCE.CLAIM
-- claim_id accepts the MySQL value when supplied by the legacy system.
-- claim.policy_id is a FK to policy.policy_id — works correctly because
-- both columns now store the same value space (MySQL EVEN ids or ODD cloud ids).
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS insurance.claim (
    claim_id            BIGINT          NOT NULL DEFAULT nextval('insurance.claim_id_seq'),
    claim_num           VARCHAR(50)     NOT NULL,
    policy_id           BIGINT          NOT NULL,
    policy_num          VARCHAR(50)     NOT NULL,
    claimant_name       VARCHAR(200)    NOT NULL,
    claim_amount        NUMERIC(12,2)   NOT NULL DEFAULT 0.00,
    claim_status        VARCHAR(30)     NOT NULL DEFAULT 'OPEN',
    incident_date       DATE            NULL,
    created_at          TIMESTAMP       NOT NULL DEFAULT NOW(),
    last_modified       TIMESTAMP       NOT NULL DEFAULT NOW(),
    datasync_flag       VARCHAR(10)     NULL,
    CONSTRAINT pk_ins_claim          PRIMARY KEY (claim_id),
    CONSTRAINT uq_ins_claim_num      UNIQUE (claim_num),
    -- claim.policy_id stores the MySQL policy_id (EVEN) or cloud policy_id (ODD).
    -- References policy.policy_id directly — no legacy indirection needed.
    CONSTRAINT fk_ins_claim_policy   FOREIGN KEY (policy_id)
                                     REFERENCES insurance.policy(policy_id)
                                     ON UPDATE CASCADE ON DELETE RESTRICT
);
COMMENT ON COLUMN insurance.claim.claim_id IS
    'Unified PK. MySQL supplies EVEN values via CDC; cloud generates ODD values via sequence.';
COMMENT ON COLUMN insurance.claim.policy_id IS
    'FK to insurance.policy.policy_id. Stores MySQL policy_id for legacy rows.';

-- ─────────────────────────────────────────────
-- INSURANCE.POLICY_KEYRING — PII tokenization vault
-- Maps policy_num → UUID (policy_uuid)
-- All new Domain APIs use policy_uuid exclusively
-- UNIQUE on legacy_policy_num = idempotency guard (Pattern 5)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS insurance.policy_keyring (
    keyring_id          BIGINT          NOT NULL DEFAULT nextval('insurance.policy_keyring_id_seq'),
    policy_uuid         UUID            NOT NULL DEFAULT gen_random_uuid(),
    legacy_policy_num   VARCHAR(50)     NOT NULL,
    created_at          TIMESTAMP       NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_policy_keyring           PRIMARY KEY (keyring_id),
    CONSTRAINT uq_policy_uuid              UNIQUE (policy_uuid),
    CONSTRAINT uq_policy_keyring_leg_num   UNIQUE (legacy_policy_num)
);
COMMENT ON TABLE insurance.policy_keyring IS
    'PII vault. policy_num → policy_uuid. '
    'UNIQUE on legacy_policy_num = idempotency guard on retry (Pattern 5). '
    'All Domain APIs use policy_uuid only.';

-- ─────────────────────────────────────────────
-- INSURANCE.CLAIM_KEYRING — PII tokenization vault
-- Maps claim_num → UUID (claim_uuid)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS insurance.claim_keyring (
    keyring_id          BIGINT          NOT NULL DEFAULT nextval('insurance.claim_keyring_id_seq'),
    claim_uuid          UUID            NOT NULL DEFAULT gen_random_uuid(),
    legacy_claim_num    VARCHAR(50)     NOT NULL,
    created_at          TIMESTAMP       NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_claim_keyring            PRIMARY KEY (keyring_id),
    CONSTRAINT uq_claim_uuid               UNIQUE (claim_uuid),
    CONSTRAINT uq_claim_keyring_leg_num    UNIQUE (legacy_claim_num)
);
COMMENT ON TABLE insurance.claim_keyring IS
    'PII vault. claim_num → claim_uuid. '
    'UNIQUE on legacy_claim_num = idempotency guard on retry (Pattern 5). '
    'All Domain APIs use claim_uuid only.';

-- ─────────────────────────────────────────────
-- METADATA.CONNECTION_REGISTRY
-- Multi-source multi-target connection resolver
-- Upstream loader resolves DB connections dynamically from here
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS metadata.connection_registry (
    connection_id       INT             NOT NULL DEFAULT nextval('metadata.conn_id_seq'),
    connection_name     VARCHAR(100)    NOT NULL,
    db_secret_arn       VARCHAR(500)    NOT NULL,
    db_host             VARCHAR(300)    NOT NULL,
    db_port             INT             NOT NULL DEFAULT 5432,
    db_name             VARCHAR(100)    NOT NULL,
    db_type             VARCHAR(20)     NOT NULL,
    is_active           BOOLEAN         NOT NULL DEFAULT true,
    created_at          TIMESTAMP       NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_connection        PRIMARY KEY (connection_id),
    CONSTRAINT uq_connection_name   UNIQUE (connection_name)
);
COMMENT ON TABLE metadata.connection_registry IS
    'Resolves source and target DB connections for upstream loader. '
    'Enables multi-source multi-target routing without hardcoded endpoints.';

-- ─────────────────────────────────────────────
-- METADATA.METADATA_MAP_MASTER
-- One row per source→target table mapping
-- One source can map to MANY targets (1-to-many decomposition)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS metadata.metadata_map_master (
    map_id              INT             NOT NULL DEFAULT nextval('metadata.map_id_seq'),
    src_connection_id   INT             NOT NULL,
    dstn_connection_id  INT             NOT NULL,
    src_schema_nam      VARCHAR(100)    NOT NULL,
    dstn_schema_nam     VARCHAR(100)    NOT NULL,
    src_tbl_nam         VARCHAR(100)    NOT NULL,
    dstn_tbl_nam        VARCHAR(100)    NOT NULL,
    src_pks             VARCHAR(200)    NOT NULL,
    dstn_pks            VARCHAR(200)    NOT NULL,
    is_active           BOOLEAN         NOT NULL DEFAULT true,
    stream_type         VARCHAR(20)     NOT NULL DEFAULT 'BOTH',
    load_order          INT             NOT NULL DEFAULT 1,
    created_at          TIMESTAMP       NOT NULL DEFAULT NOW(),
    last_modified       TIMESTAMP       NOT NULL DEFAULT NOW(),
    CONSTRAINT pk_map_master        PRIMARY KEY (map_id),
    CONSTRAINT fk_map_src_conn      FOREIGN KEY (src_connection_id)
                                    REFERENCES metadata.connection_registry(connection_id),
    CONSTRAINT fk_map_dstn_conn     FOREIGN KEY (dstn_connection_id)
                                    REFERENCES metadata.connection_registry(connection_id)
);
COMMENT ON TABLE metadata.metadata_map_master IS
    'Table-level mapping. One source → multiple targets (1-to-many). '
    'load_order controls execution sequence for same source table. '
    'stream_type: CDC | FULL_LOAD | BOTH.';

-- ─────────────────────────────────────────────
-- METADATA.METADATA_RULES
-- One row per field mapping per target table
-- Drives all dynamic DML generation in upstream loader
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS metadata.metadata_rules (
    rule_id                 INT             NOT NULL DEFAULT nextval('metadata.rule_id_seq'),
    map_id                  INT             NOT NULL,
    src_field_name          VARCHAR(200)    NOT NULL,
    src_datatype_txt        VARCHAR(100)    NOT NULL,
    dstn_field_name         VARCHAR(200)    NOT NULL,
    dstn_datatype_txt       VARCHAR(100)    NOT NULL,
    conversion_method       VARCHAR(50)     NOT NULL DEFAULT 'DIRECT',
    conversion_format_txt   VARCHAR(500)    NULL,
    column_order            INT             NOT NULL DEFAULT 1,
    created_at              TIMESTAMP       NOT NULL DEFAULT NOW(),
    last_modified           TIMESTAMP       NOT NULL DEFAULT NOW(),
    created_by              VARCHAR(100)    NOT NULL DEFAULT 'SYSTEM',
    CONSTRAINT pk_metadata_rules    PRIMARY KEY (rule_id),
    CONSTRAINT fk_rules_map         FOREIGN KEY (map_id)
                                    REFERENCES metadata.metadata_map_master(map_id)
                                    ON DELETE CASCADE
);
COMMENT ON TABLE metadata.metadata_rules IS
    'Field-level mapping rules. column_order = CSV position (COLUMN5+). '
    'conversion_method drives dynamic DML in upstream loader. '
    'DIRECT|NULL_TO_BLANK|NULL_TO_ZERO|NULL_TO_DATE|LEGACY_REF|'
    'UPPERCASE|TRIM|SKIP|UUID_GENERATE|SKIP_NULL_CONVERSION';

-- ─────────────────────────────────────────────
-- INDEXES
-- ─────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_claim_kr_legacy_num     ON insurance.claim_keyring(legacy_claim_num);
CREATE INDEX IF NOT EXISTS idx_policy_kr_legacy_num    ON insurance.policy_keyring(legacy_policy_num);
CREATE INDEX IF NOT EXISTS idx_map_src                 ON metadata.metadata_map_master(src_schema_nam, src_tbl_nam) WHERE is_active = true;
CREATE INDEX IF NOT EXISTS idx_rules_map_id            ON metadata.metadata_rules(map_id);
