# Live Data Coexistence Framework (LDCF)

[![DOI](https://zenodo.org/badge/doi/10.5281/zenodo.21313169.svg)](https://doi.org/10.5281/zenodo.21313169)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![ORCID](https://img.shields.io/badge/ORCID-0009--0009--7302--7566-brightgreen.svg)](https://orcid.org/0009-0009-7302-7566)
[![Version](https://img.shields.io/badge/Version-1.0-orange.svg)](https://doi.org/10.5281/zenodo.21313169)

**A Validated Five-Layer Bidirectional Architecture for Zero-Downtime Enterprise MIS Modernization**

*Krishan Kumar — Enterprise Architect | Distributed Systems Specialist*
*ORCID: [0009-0009-7302-7566](https://orcid.org/0009-0009-7302-7566)*

---

## Overview

Enterprise organizations running mission-critical Management Information Systems (MIS) face a modernization paradox: the systems most urgently needing replacement are precisely those that cannot be taken offline. Traditional migration strategies handle application concerns reasonably well but leave a critical gap at the data layer, where both legacy and cloud systems must simultaneously read and write consistent information for years at a time.

The **Live Data Coexistence Framework (LDCF)** is a validated five-layer bidirectional architecture that solves this problem. It enables zero-downtime enterprise MIS modernization by keeping data consistent across legacy and cloud platforms throughout the full duration of a multi-year migration program — with no application changes required on either side.

---

## Production Validation Results

| Metric | Result |
|--------|--------|
| Legacy tables migrated 
| Cloud-native tables created via schema decomposition |
| Total DML transactions processed | 
| Weekly file processing volume | 
| End-to-end replication latency | 
| Pipeline failure rate | 
| Unrecovered data loss events |
| Binary key serialization failures post-fix |


---

## Key Contributions

- **Live Data Coexistence Framework (LDCF):** Validated five-layer bidirectional architecture for zero-downtime enterprise MIS modernization
- **Eight Original Engineering Patterns:** Named, reusable solutions for coexistence integrity and correctness
- **Binary Key Bridging Pattern:** First documented systematic solution for mainframe hardware-clock-generated binary surrogate key CDC migration
- **Metadata-Driven 1-to-Many Schema Decomposition:** Breaks the CDC schema-parity assumption — enables schema modernization during active replication
- **Eventual Consistency with Bounded Drift:** Formal design principle with 24-hour drift bound enforced by automated reconciliation
- **Configuration-Driven Table Lifecycle Management:** Retire or reactivate table sync with one config change, no code deployment required

---

## Five-Layer Architecture

```
Layer 1 — Physical Replication Pipeline
          CDC ingestion from mainframe z/OS via Qlik Replicate
          and relational databases via AWS DMS
          Transaction-preserving configuration | 60-second SLA

Layer 2 — Integrity and Correctness Framework
          Eight original patterns: dual-sequence key partitioning,
          circular replication guard, last-write-wins resolution,
          upsert tolerance, three-tier DLQ audit, binary key
          bridging, metadata transformation, bounded drift

Layer 3 — Metadata-Driven Transformation Engine
          Spring Boot microservice | 1-to-many source-to-target
          mapping | PII UUID tokenization | Configuration-driven
          table lifecycle management | O(1) cache lookup

Layer 4 — Kafka Reverse Synchronization
          Domain API publishes Kafka events on state change
          Dedicated listener per legacy database type
          Direct JDBC Type 4 to mainframe DB2
          DataSYNC origin flag prevents circular loops

Layer 5 — Self-Healing Reconciliation
          Daily AWS Glue Python full-table comparison
          SNS alert with missing primary keys
          Lambda-triggered automated reprocessing
          Persistent RDS audit table
```

Full interactive architecture diagram available in the `architecture/` folder.

---

## Eight Original Integrity Patterns

| Pattern | Description |
|---------|-------------|
| Dual-Sequence Key Partitioning | Legacy uses even sequences, cloud uses odd — eliminates PK collision without coordination |
| Origin-Aware Circular Replication Guard | DataSYNC flag identifies cloud-originated writes and prevents infinite replication loops |
| Last-Write-Wins Conflict Resolution | Incoming timestamp compared against current record — older events discarded |
| Upsert Tolerance for Out-of-Order Events | INSERT ON CONFLICT DO UPDATE ensures valid state regardless of event arrival order |
| Three-Tier DLQ with Tiered Audit Persistence | Three retries via SQS DLQ, DynamoDB audit with 90-day success / 180-day failure TTL |
| Binary Key Bridging | Mainframe STCK binary surrogate keys hex-encoded at capture — converts to portable 18-character strings |
| Metadata-Driven 1-to-Many Schema Decomposition | Runtime metadata service maps one legacy table to multiple modern target tables |
| Eventual Consistency with Bounded Drift | Independent DML transactions with 24-hour drift bound enforced by daily Glue reconciliation |

---

## Technology Stack

| Layer | Component | Technology |
|-------|-----------|------------|
| Ingestion | Mainframe CDC | Qlik Replicate: agentless z/OS log reader |
| Ingestion | Relational CDC | AWS DMS: log-based DB2 / Oracle CDC |
| Transport | File landing | Amazon S3: database-partitioned buckets |
| Transport | Event trigger | AWS Lambda: S3-to-SQS Claim Check pointer |
| Transport | Message queue | Amazon SQS: decoupled event delivery |
| Processing | Upstream listener | Java Spring Boot: metadata resolution and load |
| Transformation | Schema engine | Java Spring Boot with PostgreSQL metadata and cache |
| Reverse sync | Event streaming | Apache Kafka: cloud-to-legacy domain events |
| Reverse sync | Legacy write-back | Java Spring Boot with JDBC Type 4 to DB2/z/OS |
| Audit | Event audit log | Amazon DynamoDB: tiered TTL audit and retry |
| Reconciliation | Drift detection | AWS Glue Python: daily full-table comparison |
| Alerting | Notifications | Amazon SNS: email alert with missing primary keys |
| Target | Cloud database | Amazon Aurora PostgreSQL: multi-AZ |

---

## Repository Structure

```
live-data-coexistence-framework/
│
├── whitepaper/
│   └── README.md                    # Links to published paper on Zenodo
│
├── architecture/
│   ├── ldcf-full-architecture.md    # Full five-layer Mermaid diagram
│   ├── layer1-replication.md        # Layer 1 detail diagram
│   ├── layer2-integrity.md          # Layer 2 detail diagram
│   ├── layer3-metadata.md           # Layer 3 detail diagram
│   ├── layer4-kafka.md              # Layer 4 detail diagram
│   └── layer5-reconciliation.md     # Layer 5 detail diagram
│
├── docs/
│   ├── deployment-guide.md          # End-to-end deployment guide
│   ├── aws-setup.md                 # AWS infrastructure setup
│   ├── metadata-engine.md           # Metadata engine documentation
│   └── faq.md                       # Frequently asked questions
│
├── implementation/
│   └── poccode/
│       ├── setup/                   # SQL schema scripts and metadata seed data
│       ├── lambda/                  # AWS Lambda functions for upstream sync pipeline
│       └── cloudformation/          # Five CloudFormation stacks, deploy.sh, cleanup.sh
│
├── CITATION.cff                     # Citation metadata for GitHub and Google Scholar
├── LICENSE                          # Apache 2.0 License
└── README.md                        # This file
```

---

## White Paper

The full paper is published on Zenodo (open access, Apache 2.0):

**[Live Data Coexistence Framework: A Validated Bidirectional Architecture for Zero-Downtime Enterprise MIS Modernization](https://doi.org/10.5281/zenodo.21313169)**

| | |
|--|--|
| DOI | [10.5281/zenodo.21313169](https://doi.org/10.5281/zenodo.21313169) |
| Version | 1.0 |
| Published | July 11, 2026 |
| License | Apache 2.0 |
| Pages | 33 |
| Tables | 5 |
| Patterns | 8 original |

---

## Quick Start

### Prerequisites
- AWS account with appropriate IAM permissions
- Java 17+
- PostgreSQL 14+
- Apache Kafka 3.x

### Deploy the POC Infrastructure

```bash
# Clone the repository
git clone https://github.com/krishankumar-arch/live-data-coexistence-framework.git
cd live-data-coexistence-framework

# Deploy AWS infrastructure
cd implementation/poccode/cloudformation
chmod +x deploy.sh
./deploy.sh

# Initialize metadata schema
cd ../setup
psql -h <aurora-endpoint> -U <username> -d <database> -f schema.sql
psql -h <aurora-endpoint> -U <username> -d <database> -f seed-data.sql
```

Full deployment instructions in [`docs/deployment-guide.md`](docs/deployment-guide.md).

---

## Citation

If you use LDCF in your research or production work, please cite:

**APA 7th Edition:**
```
Kumar, K. (2026). Live Data Coexistence Framework: A validated 
bidirectional architecture for zero-downtime enterprise MIS 
modernization. Zenodo. 
https://doi.org/10.5281/zenodo.21313169
```

**BibTeX:**
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

## License

This project is licensed under the **Apache License 2.0**.
See the [LICENSE](LICENSE) file for full terms.

Copyright 2026 Krishan Kumar

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

```
https://www.apache.org/licenses/LICENSE-2.0
```

---

## Author

**Krishan Kumar**
Enterprise Architect | Distributed Systems Specialist

- ORCID: [0009-0009-7302-7566](https://orcid.org/0009-0009-7302-7566)
- LinkedIn: [linkedin.com/in/krishan2aws](https://www.linkedin.com/in/krishan2aws/)
- Paper: [doi.org/10.5281/zenodo.21313169](https://doi.org/10.5281/zenodo.21313169)

---

*The Live Data Coexistence Framework grew directly out of production 
engineering work on a large-scale insurance management modernization 
program. The patterns documented here were encountered, solved, and 
validated in a live production environment before being formalized. 
This is not a theoretical proposal — it is a documented account of 
decisions made under real constraints, with real consequences, shared 
freely with the engineering community.*
