# Live Data Coexistence Framework (LDCF) — POC

[![DOI](https://zenodo.org/badge/doi/10.5281/zenodo.21313169.svg)](https://doi.org/10.5281/zenodo.21313169)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![ORCID](https://img.shields.io/badge/ORCID-0009--0009--7302--7566-brightgreen.svg)](https://orcid.org/0009-0009-7302-7566)
[![Version](https://img.shields.io/badge/Version-1.0-orange.svg)](https://doi.org/10.5281/zenodo.21313169)

**A Validated Five-Layer Bidirectional Architecture for Zero-Downtime Enterprise MIS Modernization**

*Krishan Kumar — Enterprise Architect | Distributed Systems Specialist*
*ORCID: [0009-0009-7302-7566](https://orcid.org/0009-0009-7302-7566)*

---

## Disclaimer

> This is a **personal, non-commercial project** created independently for
> professional development and contribution to the engineering community.
> It is not affiliated with, endorsed by, or representative of any current
> or former employer. All architectural patterns, code, and documentation
> are original work shared freely with the engineering community under the
> Apache 2.0 license. No proprietary, confidential, or client-specific
> information is included. All example data is fictional and anonymized.

---

## About This POC

This proof-of-concept demonstrates the **Live Data Coexistence Framework (LDCF)**
— a validated architecture for zero-downtime enterprise system modernization.

**Insurance claims processing** is used as the example domain for clarity.
The framework and all eight patterns are **universally applicable** to any
organization running a complex legacy modernization program:

| Domain | Example Use Case |
|--------|-----------------|
| Banking | Core banking system to cloud-native platform |
| Healthcare | Legacy EMR to modern cloud health records |
| Government | Legacy case management modernization |
| Retail | Monolithic ERP to microservices migration |
| Insurance | Claims and policy system modernization |
| **Any enterprise** | Any multi-year legacy migration program |

The framework solves the fundamental enterprise challenge: **systems most
urgently needing modernization are precisely those that cannot go offline.**

---

## White Paper

> Kumar, K. (2026). *Live Data Coexistence Framework: A Validated Bidirectional
> Architecture for Zero-Downtime Enterprise MIS Modernization.* arXiv cs.DC.
> https://github.com/krishankumar-arch/live-data-coexistence-framework

---

## Architecture

```
LEGACY SOURCE (RDS MySQL)
  insurance.claim | insurance.policy | Even sequences
         │ Binary log
    ┌────▼─────┐
    │ AWS DMS  │  Task 1: Full load │ Task 2: CDC → pipe-separated CSV
    └────┬─────┘
         │ CSV files
    ┌────▼──────┐
    │ Amazon S3 │  Per-database landing bucket
    └────┬──────┘
         │ ObjectCreated
  ┌──────▼──────────┐
  │ Lambda 1        │  Claim Check — SQS pointer only (never passes CSV)
  └──────┬──────────┘
         │ < 1KB pointer + MessageAttributes
  ┌──────▼──────────┐
  │ Amazon SQS      │  retry_count | is_retry as MessageAttributes
  └──────┬──────────┘
         │
  ┌──────▼──────────┐     ┌─────────────────┐
  │ Lambda 2        │────►│ Lambda 3        │
  │ Upstream Loader │     │ Metadata Service│
  │ All 8 patterns  │     │ connection_reg  │
  └──────┬──────────┘     │ map_master      │
         │                │ metadata_rules  │
    ┌────▼──────────────────────────────────────┐
    │ Aurora PostgreSQL                         │
    │ insurance: claim, policy,                 │
    │            claim_keyring, policy_keyring  │
    │ metadata:  connection_registry,           │
    │            metadata_map_master,           │
    │            metadata_rules                 │
    └───────────────────────────────────────────┘
         │ DLQ
  ┌──────▼──────────┐
  │ Lambda 4        │  DLQ Requeue — retry_count check, requeue or PERMANENT_FAIL
  └─────────────────┘
```

---

## Eight Patterns Demonstrated

| # | Pattern | Where |
|---|---------|-------|
| 1 | Dual-Sequence Key Partitioning | MySQL even, Aurora odd sequences |
| 2 | Origin-Aware Circular Replication Guard | datasync_flag CLOUD check |
| 3 | Last-Write-Wins Conflict Resolution | last_modified comparison on U |
| 4 | Upsert Tolerance | INSERT ON CONFLICT DO UPDATE |
| 5 | Three-Tier DLQ + DynamoDB Audit | Lambda 4 + 90d/180d TTL |
| 6 | Binary Key Bridging | utilities/BinaryKeyTransform |
| 7 | Metadata-Driven 1-to-Many Decomposition | claim → claim + claim_keyring |
| 8 | Eventual Consistency with Bounded Drift | Independent DML transactions |

---

## Prerequisites

- AWS account with billing enabled
- AWS CLI configured (`aws configure`, region us-east-1)
- Python 3.11+, MySQL client, PostgreSQL client, zip

```bash
# Verify AWS CLI
aws sts get-caller-identity
```

---

## Deployment — Step by Step

### Step 1 — Deploy Infrastructure
```bash
cd cloudformation
chmod +x deploy.sh cleanup.sh
./deploy.sh
```

### Step 2 — Run Database Setup (when deploy.sh pauses)
```bash
# Endpoints printed by deploy.sh — also available via:
MYSQL_HOST=$(aws cloudformation describe-stacks \
  --stack-name ldcf-poc-databases \
  --query 'Stacks[0].Outputs[?OutputKey==`MySQLEndpoint`].OutputValue' \
  --output text)
AURORA_HOST=$(aws cloudformation describe-stacks \
  --stack-name ldcf-poc-databases \
  --query 'Stacks[0].Outputs[?OutputKey==`AuroraEndpoint`].OutputValue' \
  --output text)

mysql -h $MYSQL_HOST -u ldcfadmin -p < ../setup/01_mysql_legacy_schema.sql
psql -h $AURORA_HOST -U ldcfadmin -d ldcfdb -f ../setup/02_aurora_target_schema.sql
psql -h $AURORA_HOST -U ldcfadmin -d ldcfdb -f ../setup/03_metadata_seed.sql
```

### Step 3 — Start DMS Task 1 (Full Load)
Start from AWS Console: DMS → Replication Tasks → ldcf-poc-fullload → Start.
Wait for status: **Load complete**.

### Step 4 — Run Keyring Load (run between Task 1 and Task 2)
```bash
psql -h $AURORA_HOST -U ldcfadmin -d ldcfdb -f ../setup/04_keyring_oneshot_load.sql
```

### Step 5 — Start DMS Task 2 (CDC)
Start from AWS Console: DMS → Replication Tasks → ldcf-poc-cdc → Start.
CDC replication is now live.

### Step 6 — Test
```bash
# Insert test record in MySQL
mysql -h $MYSQL_HOST -u ldcfadmin -p insurance -e "
  INSERT INTO claim (claim_num, policy_id, policy_num,
    claimant_name, claim_amount, claim_status, incident_date)
  VALUES ('CLM-TEST-001', 1000000, 'POL-2024-0001',
    'Test User', 9999.00, 'OPEN', CURDATE());"

# Wait 60 seconds for CDC cycle, then verify in Aurora
sleep 65
psql -h $AURORA_HOST -U ldcfadmin -d ldcfdb -c \
  "SELECT c.claim_num, k.claim_uuid
   FROM insurance.claim c
   JOIN insurance.claim_keyring k ON k.legacy_claim_num = c.claim_num
   WHERE c.claim_num = 'CLM-TEST-001';"
```

---

## Day-to-Day Operations

```bash
./cleanup.sh              # Pause everything (keep infrastructure, near-zero cost)
./cleanup.sh --resume     # Resume from paused state
./cleanup.sh --destroy-all  # Delete everything (requires typing DESTROY)
```

**Estimated cost:**
- Running: ~$3-5/day
- Paused: ~$0.10/day
- Destroyed: $0

---

## Repository Structure

```
poc-code/
├── README.md
├── setup/
│   ├── 01_mysql_legacy_schema.sql      Legacy source schema + seed data
│   ├── 02_aurora_target_schema.sql     Cloud target schema (insurance + metadata)
│   ├── 03_metadata_seed.sql            Metadata mappings and rules
│   └── 04_keyring_oneshot_load.sql     One-time UUID keyring population
├── lambda/
│   ├── 01_claim_check/                 S3 trigger → SQS Claim Check pointer
│   ├── 02_upstream_loader/             Core engine — all 8 patterns
│   ├── 03_metadata_service/            Mapping resolver for upstream loader
│   └── 04_dlq_requeue/                 DLQ retry handler
└── cloudformation/
    ├── 01_network.yaml                 VPC, subnets, security groups
    ├── 02_databases.yaml               RDS MySQL + Aurora PostgreSQL
    ├── 03_pipeline.yaml                S3, SQS, DynamoDB, SNS
    ├── 04_lambdas.yaml                 All 4 Lambda functions + IAM
    ├── 05_dms.yaml                     DMS instance, endpoints, tasks
    ├── deploy.sh                       Deploy all stacks in order
    └── cleanup.sh                      Pause / resume / destroy
```

---

## Citation

```bibtex
@misc{kumar2026ldcf,
  title     = {Live Data Coexistence Framework: A Validated Bidirectional
               Architecture for Zero-Downtime Enterprise MIS Modernization},
  author    = {Kumar, Krishan},
  year      = {2026},
  publisher = {Zenodo},
  doi       = {10.5281/zenodo.21313169},
  url       = {https://doi.org/10.5281/zenodo.21313169},
  note      = {ORCID: 0009-0009-7302-7566}
}
```

---

*© 2026 Krishan Kumar. Apache 2.0 License.*
