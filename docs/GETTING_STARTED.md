# Getting Started with LDCF

> From zero to running POC in under 30 minutes.

---

## Prerequisites

- [ ] AWS account ([setup guide](AWS_SETUP.md))
- [ ] AWS CLI configured (`aws sts get-caller-identity` works)
- [ ] Python 3.11+
- [ ] MySQL client (`mysql --version`)
- [ ] PostgreSQL client (`psql --version`)
- [ ] `zip` utility

---

## 1. Clone the Repository

```bash
git clone https://github.com/krishankumar-arch/live-data-coexistence-framework.git
cd live-data-coexistence-framework
```

---

## 2. Deploy Infrastructure

```bash
cd implementation/poc-code/cloudformation
chmod +x deploy.sh cleanup.sh
./deploy.sh
```

Follow the prompts. The script pauses at the right moments and
tells you exactly what to do at each step.

Total deploy time: ~20 minutes.

---

## 3. Understand the Architecture

- [Five-Layer Architecture](../architecture/FIVE_LAYER_ARCHITECTURE.md)
- [Eight Integrity Patterns](../architecture/EIGHT_PATTERNS.md)
- [End-to-End Data Flow](../architecture/DATA_FLOW.md)
- [Metadata Engine Design](METADATA_ENGINE.md)

---

## 4. Read the White Paper

[whitepaper/LDCF_WhitePaper_v1.md](../whitepaper/LDCF_WhitePaper_v1.md)

---

## 5. Pause / Resume / Destroy

```bash
./cleanup.sh              # Pause (near-zero cost)
./cleanup.sh --resume     # Resume
./cleanup.sh --destroy-all  # Delete everything
```

---

## Troubleshooting

**DMS task stuck in starting:**
Wait 5 minutes. DMS replication instance takes time to become available.

**Lambda timeout on first invocation:**
Cold start with psycopg2 can take 3-5 seconds. Timeout set to 30s — should be fine.

**Aurora connection refused:**
Check security group allows port 5432 from Lambda SG (handled by CloudFormation).

**DynamoDB PERMANENT_FAILED records:**
Check CloudWatch logs for Lambda 2 → find error → fix root cause →
set `reprocess_flag=true` in DynamoDB → Lambda will reprocess on next run.
