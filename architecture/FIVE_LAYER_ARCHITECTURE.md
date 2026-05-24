# LDCF Five-Layer Architecture Diagram

> Mermaid diagram — renders in GitHub automatically

```mermaid
flowchart TD
    subgraph SRC["🏛️ Legacy Sources"]
        MF["Mainframe z/OS\nBinary STCK keys"]
        DB2["DB2"]
        ORA["Oracle"]
        MYSQL["MySQL / MSSQL"]
    end

    subgraph L1["Layer 1 — Physical Replication Pipeline"]
        QLIK["Qlik Replicate\nAgentless z/OS CDC"]
        DMS["AWS DMS\nLog-based CDC\nBatchApplyPreserveTx=true"]
        S3["Amazon S3\nPipe-separated CSV\nLanding Zone"]
        LMB1["Lambda 1\nClaim Check Handler\nSQS pointer only"]
        SQS["Amazon SQS\nEvent Queue\n&lt;1KB pointer"]
    end

    subgraph L2["Layer 2 — Integrity & Correctness"]
        LMB2["Lambda 2\nUpstream Loader\n8 Integrity Patterns"]
        P1["Pattern 1\nEven/Odd Key\nPartitioning"]
        P2["Pattern 2\nCircular\nReplication Guard"]
        P3["Pattern 3\nLast-Write-Wins\nResolution"]
        P4["Pattern 4\nUpsert Tolerance\nON CONFLICT"]
    end

    subgraph L3["Layer 3 — Metadata Transformation Engine"]
        LMB3["Lambda 3\nMetadata Service"]
        MMM["metadata_map_master\n1-to-many mappings"]
        MR["metadata_rules\nField-level conversion"]
        CR["connection_registry\nMulti-source routing"]
        DDB["DynamoDB\nAudit Log\n90d/180d TTL"]
    end

    subgraph L4["Layer 4 — Kafka Reverse Sync"]
        API["Domain API\nCloud Microservice"]
        KP["Kafka Producer\nDomain Events"]
        KL["Kafka Listener\nSpring Boot"]
        DSF["datasync_flag=CLOUD\nCircular Loop Guard"]
    end

    subgraph L5["Layer 5 — Self-Healing Reconciliation"]
        GLUE["AWS Glue\nDaily Full Comparison"]
        SNS["Amazon SNS\nAlert — Missing PKs"]
        RDS_AUD["RDS Audit Table\nDrift Log"]
        LMB4["Lambda 4\nDLQ Requeue\nRetry Orchestration"]
    end

    subgraph TGT["☁️ Cloud Target — Aurora PostgreSQL"]
        CLM["insurance.claim\nODD sequences"]
        POL["insurance.policy\nODD sequences"]
        CLK["claim_keyring\nUUID tokenization"]
        PLK["policy_keyring\nUUID tokenization"]
    end

    MF --> QLIK
    DB2 --> DMS
    ORA --> DMS
    MYSQL --> DMS
    QLIK --> S3
    DMS --> S3
    S3 -->|ObjectCreated| LMB1
    LMB1 -->|Claim Check pointer| SQS
    SQS --> LMB2
    LMB2 --- P1
    LMB2 --- P2
    LMB2 --- P3
    LMB2 --- P4
    LMB2 -->|invoke| LMB3
    LMB3 --- MMM
    LMB3 --- MR
    LMB3 --- CR
    LMB2 --> DDB
    LMB2 --> CLM
    LMB2 --> POL
    LMB2 --> CLK
    LMB2 --> PLK
    LMB2 -->|on failure| LMB4
    LMB4 -->|requeue| SQS
    API --> KP
    KP --> KL
    KL -->|JDBC Type 4| DSF
    DSF -->|writes to legacy| DB2
    CLM --> GLUE
    POL --> GLUE
    GLUE --> SNS
    GLUE --> RDS_AUD
    RDS_AUD -->|reprocess flag| LMB2

    style SRC fill:#fff3e0,stroke:#ff9800
    style L1  fill:#e3f2fd,stroke:#1976d2
    style L2  fill:#e8f5e9,stroke:#388e3c
    style L3  fill:#fff8e1,stroke:#f57c00
    style L4  fill:#f3e5f5,stroke:#7b1fa2
    style L5  fill:#e0f2f1,stroke:#00796b
    style TGT fill:#e8eaf6,stroke:#3f51b5
```

---

## Layer Responsibilities Summary

| Layer | Name | Primary AWS Services |
|-------|------|---------------------|
| 1 | Physical Replication Pipeline | AWS DMS, Amazon S3, AWS Lambda, Amazon SQS |
| 2 | Integrity & Correctness | AWS Lambda, Amazon SQS DLQ |
| 3 | Metadata Transformation | AWS Lambda, Amazon Aurora, Amazon DynamoDB |
| 4 | Kafka Reverse Sync | Amazon MSK, Spring Boot on ECS/EC2 |
| 5 | Self-Healing Reconciliation | AWS Glue, Amazon SNS, Amazon RDS, AWS Lambda |
