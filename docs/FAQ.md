# Frequently Asked Questions

---

**Q: Is this only for insurance companies?**

No. Insurance is the example domain. The framework applies to any enterprise
with legacy systems undergoing multi-year modernization: banking, healthcare,
government, retail, manufacturing. The patterns are domain-agnostic.

---

**Q: Does this require Qlik Replicate?**

No. Qlik Replicate is used for mainframe z/OS CDC (agentless, no changes
to mainframe required). For standard relational databases (MySQL, Oracle,
MSSQL, PostgreSQL), AWS DMS is used. The POC uses AWS DMS only.

---

**Q: What databases are supported as source?**

Any database supported by AWS DMS as a source: MySQL, PostgreSQL, Oracle,
MSSQL, MariaDB, MongoDB, and others. For mainframe z/OS, Qlik Replicate
is recommended. The metadata engine is database-agnostic.

---

**Q: Can I use this for cloud-to-cloud migration?**

Yes. The source does not need to be a legacy system. Any database supported
by DMS can be a source. The patterns work equally well for cloud-to-cloud
schema migration or database engine migration.

---

**Q: What happens if the DMS task fails?**

DMS CDC maintains a checkpoint. When restarted, it resumes from the last
committed checkpoint — no data is lost. The `cleanup.sh --resume` command
restarts DMS from the last checkpoint automatically.

---

**Q: How do I add a new source table?**

Insert rows into `metadata_map_master` and `metadata_rules`. No code change,
no Lambda redeployment. The metadata cache refreshes on Lambda cold start.

---

**Q: Is the framework production-ready?**

The patterns are validated in production (insurance sector, Dec 2024–present,
1M+ transactions, <0.1% failure rate). This POC is a reference implementation
for educational purposes. Production deployment requires additional hardening:
VPC private subnets, enhanced IAM policies, CloudWatch alarms, etc.

---

**Q: How do I cite this work?**

See [CITATION.cff](../CITATION.cff) in the repository root, or:

> Kumar, K. (2026). *Live Data Coexistence Framework.* arXiv cs.DC.
> https://github.com/krishankumar-arch/live-data-coexistence-framework
