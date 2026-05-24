-- ═══════════════════════════════════════════════════════════════
-- LDCF POC — File 1/4: Legacy Source Schema (MySQL / RDS MySQL)
-- Author: Krishan Kumar | ORCID: 0009-0009-7302-7566
--
-- PURPOSE:
--   Creates legacy source database. Insurance is the example domain.
--   Patterns apply universally to banking, healthcare, retail, etc.
--
-- PATTERN 1 — Dual-Sequence Key Partitioning:
--   AUTO_INCREMENT starts at EVEN number.
--   EVEN = legacy-generated. ODD = cloud-generated (Aurora side).
--
-- PATTERN 2 — Circular Replication Guard:
--   datasync_flag column on every table.
--   NULL = legacy origin (replicate). CLOUD = skip (prevent loop).
--
-- RDS PARAMETER GROUP — set before creating DMS replication instance:
--   binlog_format    = ROW
--   binlog_row_image = FULL
--   binlog_checksum  = NONE
-- ═══════════════════════════════════════════════════════════════

CREATE DATABASE IF NOT EXISTS insurance
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE insurance;

-- ─────────────────────────────────────────────
-- POLICY — parent table (create first)
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS policy (
    policy_id           BIGINT          NOT NULL  AUTO_INCREMENT,
    policy_num          VARCHAR(50)     NOT NULL,
    policy_holder_name  VARCHAR(200)    NOT NULL,
    policy_type         VARCHAR(50)     NOT NULL,
    effective_date      DATE            NOT NULL,
    expiry_date         DATE            NOT NULL,
    premium_amount      DECIMAL(12,2)   NOT NULL  DEFAULT 0.00,
    created_at          DATETIME        NOT NULL  DEFAULT CURRENT_TIMESTAMP,
    last_modified       DATETIME        NOT NULL  DEFAULT CURRENT_TIMESTAMP
                                                  ON UPDATE CURRENT_TIMESTAMP,
    datasync_flag       VARCHAR(10)     NULL
                        COMMENT 'NULL=legacy | CLOUD=written by reverse sync',
    CONSTRAINT pk_policy        PRIMARY KEY (policy_id),
    CONSTRAINT uq_policy_num    UNIQUE      (policy_num)
-- PATTERN 1: even start
) ENGINE=InnoDB AUTO_INCREMENT=1000000
  COMMENT='Legacy policy master. Even PK = legacy origin (LDCF Pattern 1).';

-- ─────────────────────────────────────────────
-- CLAIM — child of POLICY
-- ─────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS claim (
    claim_id            BIGINT          NOT NULL  AUTO_INCREMENT,
    claim_num           VARCHAR(50)     NOT NULL,
    policy_id           BIGINT          NOT NULL,
    policy_num          VARCHAR(50)     NOT NULL,
    claimant_name       VARCHAR(200)    NOT NULL,
    claim_amount        DECIMAL(12,2)   NOT NULL  DEFAULT 0.00,
    claim_status        VARCHAR(30)     NOT NULL  DEFAULT 'OPEN',
    incident_date       DATE            NULL,
    created_at          DATETIME        NOT NULL  DEFAULT CURRENT_TIMESTAMP,
    last_modified       DATETIME        NOT NULL  DEFAULT CURRENT_TIMESTAMP
                                                  ON UPDATE CURRENT_TIMESTAMP,
    datasync_flag       VARCHAR(10)     NULL
                        COMMENT 'NULL=legacy | CLOUD=written by reverse sync',
    CONSTRAINT pk_claim         PRIMARY KEY (claim_id),
    CONSTRAINT uq_claim_num     UNIQUE      (claim_num),
    CONSTRAINT fk_claim_policy  FOREIGN KEY (policy_id)
                                REFERENCES  policy(policy_id)
                                ON UPDATE CASCADE ON DELETE RESTRICT
-- PATTERN 1: even start
) ENGINE=InnoDB AUTO_INCREMENT=2000000
  COMMENT='Legacy claims. Even PK = legacy origin (LDCF Pattern 1).';

-- ─────────────────────────────────────────────
-- SAMPLE DATA — 5 policies, 10 claims
-- Anonymized — no real personal data
-- ─────────────────────────────────────────────
INSERT INTO policy (policy_num, policy_holder_name, policy_type,
                    effective_date, expiry_date, premium_amount)
VALUES
    ('POL-2024-0001', 'Acme Corporation',     'AUTO',   '2024-01-01', '2025-01-01', 1200.00),
    ('POL-2024-0002', 'Globex Industries',    'HOME',   '2024-02-01', '2025-02-01',  850.00),
    ('POL-2024-0003', 'Springfield Partners', 'AUTO',   '2024-03-01', '2025-03-01', 1450.00),
    ('POL-2024-0004', 'Initech Group',        'HEALTH', '2024-04-01', '2025-04-01', 3200.00),
    ('POL-2024-0005', 'Umbrella Holdings',    'HOME',   '2024-05-01', '2025-05-01',  975.00);

INSERT INTO claim (claim_num, policy_id, policy_num,
                   claimant_name, claim_amount, claim_status, incident_date)
VALUES
    ('CLM-2024-0001', 1000000, 'POL-2024-0001', 'J. Smith',     5000.00, 'OPEN',         '2024-06-01'),
    ('CLM-2024-0002', 1000000, 'POL-2024-0001', 'J. Smith',     1200.00, 'APPROVED',     '2024-07-15'),
    ('CLM-2024-0003', 1000002, 'POL-2024-0002', 'J. Doe',       8500.00, 'UNDER_REVIEW', '2024-08-01'),
    ('CLM-2024-0004', 1000004, 'POL-2024-0003', 'R. Johnson',   3200.00, 'OPEN',         '2024-08-20'),
    ('CLM-2024-0005', 1000006, 'POL-2024-0004', 'A. Williams', 15000.00, 'APPROVED',     '2024-09-01'),
    ('CLM-2024-0006', 1000006, 'POL-2024-0004', 'A. Williams',  4500.00, 'REJECTED',     '2024-09-15'),
    ('CLM-2024-0007', 1000008, 'POL-2024-0005', 'C. Brown',     2800.00, 'CLOSED',       '2024-10-01'),
    ('CLM-2024-0008', 1000000, 'POL-2024-0001', 'J. Smith',      900.00, 'OPEN',         '2024-10-20'),
    ('CLM-2024-0009', 1000002, 'POL-2024-0002', 'J. Doe',       6700.00, 'UNDER_REVIEW', '2024-11-01'),
    ('CLM-2024-0010', 1000004, 'POL-2024-0003', 'R. Johnson',   1100.00, 'APPROVED',     '2024-11-15');

-- Verify: SELECT policy_id, policy_id % 2 AS must_be_zero FROM policy LIMIT 5;
