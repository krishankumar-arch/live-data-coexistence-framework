# Live Data Coexistence Framework (LDCF)

> **A Validated Architecture for Zero-Downtime Enterprise Legacy Modernization**

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![arXiv](https://img.shields.io/badge/arXiv-cs.DC-red)](https://arxiv.org/abs/TBD)
[![ORCID](https://img.shields.io/badge/ORCID-0009--0009--7302--7566-green)](https://orcid.org/0009-0009-7302-7566)
[![AWS](https://img.shields.io/badge/AWS-Powered-orange)](https://aws.amazon.com)

---

## Disclaimer

> This is a **personal, non-commercial project** created independently for
> professional development and free contribution to the engineering community.
> It is not affiliated with, endorsed by, or representative of any current
> or former employer. All architectural patterns, source code, and documentation
> are original work. No proprietary, confidential, or client-specific information
> is included. All example data is fictional and anonymized.
>
> *Shared freely with the global engineering community under Apache 2.0.*

---

## What Is LDCF?

The Live Data Coexistence Framework is a battle-tested architecture that solves
the most challenging problem in enterprise modernization:

> **How do you modernize a mission-critical system that processes millions of
> transactions and cannot be taken offline — while a multi-year cloud migration
> is underway?**

LDCF enables **legacy and cloud systems to coexist simultaneously**, sharing
live data bidirectionally, with zero data loss and no downtime.

---

## The Problem It Solves

Every large enterprise faces this paradox:

```
Legacy System                    Cloud Target
─────────────────                ─────────────────────
✗ Cannot modernize fast          ✗ Cannot have stale data
✗ Cannot go offline              ✗ Cannot wait for full cutover
✗ Has 100s of dependents         ✗ Needs modern schema design
✗ Complex legacy schema          ✗ Must support rollback at any time
         │                                    │
         └──────────── ??? ───────────────────┘
```

LDCF bridges this gap with five AWS-powered layers that keep both systems
in sync throughout a multi-year migration program.

---

## Who This Is For

While this repository uses **insurance claims processing** as the example domain,
the framework and all patterns apply universally to:

| Industry | Modernization Challenge |
|----------|------------------------|
| **Banking** | Core banking → cloud-native platform |
| **Healthcare** | Legacy EMR → modern health records |
| **Insurance** | Claims/policy systems → microservices |
| **Government** | Legacy case management modernization |
| **Retail** | Monolithic ERP → event-driven platform |
| **Any Enterprise** | Any multi-year legacy migration program |

---

## Five-Layer Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Layer 1 — Physical Replication Pipeline                             │
│  Legacy DB → Qlik/DMS → CSV → S3 → Lambda(Claim Check) → SQS        │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 2 — Integrity & Correctness (8 Original Patterns)             │
│  Circular guard · Last-write-wins · Upsert tolerance · Even/odd keys │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 3 — Metadata Transformation Engine                            │
│  1-to-many schema decomposition · Dynamic DML · PII tokenization     │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 4 — Kafka Reverse Sync (Cloud → Legacy)                       │
│  Domain API → Kafka → Spring Boot → JDBC → Legacy DB                 │
├──────────────────────────────────────────────────────────────────────┤
│  Layer 5 — Self-Healing Reconciliation                               │
│  AWS Glue · SNS alerts · DynamoDB audit · Lambda reprocess           │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Eight Original Integrity Patterns

| # | Pattern | Problem Solved |
|---|---------|---------------|
| 1 | **Dual-Sequence Key Partitioning** | PK collision between legacy and cloud inserts |
| 2 | **Origin-Aware Circular Replication Guard** | Infinite replication loops in bidirectional sync |
| 3 | **Last-Write-Wins Conflict Resolution** | Stale updates overwriting newer cloud records |
| 4 | **Upsert Tolerance** | Out-of-order CDC events causing duplicate key errors |
| 5 | **Three-Tier DLQ + Tiered Audit Persistence** | Unrecoverable failures with no audit trail |
| 6 | **Binary Key Bridging** | 9-byte STCK binary mainframe keys in VARCHAR columns |
| 7 | **Metadata-Driven 1-to-Many Decomposition** | One legacy table → multiple modern normalized tables |
| 8 | **Eventual Consistency with Bounded Drift** | Unbounded data drift during coexistence period |

---

## Production Results

Deployed in a production insurance modernization program (Dec 2024 – present):

| Metric | Result |
|--------|--------|
| Legacy tables migrated | 300+ |
| Cloud-only tables created | 50+ |
| DML transactions processed | 1M+ |
| Files processed per week | ~1.2M |
| Pipeline failure rate | < 0.1% |
| Unrecovered data loss events | **Zero** |

---

## Repository Structure

```
live-data-coexistence-framework/
│
├── README.md                        ← You are here
├── LICENSE                          ← Apache 2.0
├── CITATION.cff                     ← Citation metadata
├── .gitignore
│
├── whitepaper/                      ← Published research paper
│   ├── LDCF_WhitePaper_v1.md        ← Full paper (Markdown)
│   └── REFERENCES.md                ← Bibliography
│
├── architecture/                    ← Architecture diagrams
│   ├── ARCHITECTURE_OVERVIEW.md     ← Five-layer narrative
│   ├── FIVE_LAYER_ARCHITECTURE.md   ← Mermaid diagram
│   ├── DATA_FLOW.md                 ← End-to-end data flow
│   └── EIGHT_PATTERNS.md            ← Pattern reference
│
├── docs/                            ← Developer documentation
│   ├── GETTING_STARTED.md
│   ├── AWS_SETUP.md                 ← AWS account + CLI setup
│   ├── PATTERNS_DEEP_DIVE.md        ← Detailed pattern guide
│   ├── METADATA_ENGINE.md           ← Metadata service design
│   └── FAQ.md
│
└── implementation/
    └── poc-code/                    ← Deployable AWS POC
        ├── README.md                ← POC deployment guide
        ├── setup/                   ← SQL setup scripts
        ├── lambda/                  ← Four Lambda functions
        └── cloudformation/          ← Five CF stacks + deploy/cleanup
```

---

## Quick Start

```bash
git clone https://github.com/krishankumar-arch/live-data-coexistence-framework.git
cd live-data-coexistence-framework/implementation/poc-code/cloudformation
./deploy.sh
```

See [implementation/poc-code/README.md](implementation/poc-code/README.md)
for the complete step-by-step deployment guide.

---

## White Paper

> Kumar, K. (2026). *Live Data Coexistence Framework: A Validated Bidirectional
> Architecture for Zero-Downtime Enterprise MIS Modernization.*
> arXiv preprint cs.DC. https://arxiv.org/abs/TBD

Read the full paper: [whitepaper/LDCF_WhitePaper_v1.md](whitepaper/LDCF_WhitePaper_v1.md)

---

## Citation

```bibtex
@article{kumar2026ldcf,
  title   = {Live Data Coexistence Framework: A Validated Bidirectional
             Architecture for Zero-Downtime Enterprise MIS Modernization},
  author  = {Kumar, Krishan},
  year    = {2026},
  journal = {arXiv preprint cs.DC},
  url     = {https://arxiv.org/abs/TBD},
  note    = {ORCID: 0009-0009-7302-7566}
}
```

---

## License

Apache License 2.0 — free to use, modify, and distribute with attribution.

© 2026 Krishan Kumar. All rights reserved.
