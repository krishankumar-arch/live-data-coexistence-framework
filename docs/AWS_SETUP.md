# AWS Account & CLI Setup Guide

> Complete guide for setting up your AWS environment to deploy the LDCF POC.

---

## Step 1 — Create AWS Account

If you do not have one: https://aws.amazon.com/free

Free tier covers most POC components for 12 months.

---

## Step 2 — Install AWS CLI

**macOS:**
```bash
brew install awscli
```

**Windows:**
Download installer from https://aws.amazon.com/cli/

**Linux:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install
```

Verify:
```bash
aws --version
# Expected: aws-cli/2.x.x
```

---

## Step 3 — Create IAM User

1. Sign in to AWS Console → IAM → Users → Create User
2. Name: `ldcf-poc-deployer`
3. Attach policy: `AdministratorAccess` (for POC only)
4. Security Credentials tab → Create Access Key → CLI use case
5. **Download the CSV — keep it safe, never commit to GitHub**

---

## Step 4 — Configure AWS CLI

```bash
aws configure
```

```
AWS Access Key ID:     [paste from CSV]
AWS Secret Access Key: [paste from CSV]
Default region name:   us-east-1
Default output format: json
```

Credentials stored at `~/.aws/credentials` on Mac/Linux.
**Add `.aws/` to your `.gitignore` — never commit credentials.**

---

## Step 5 — Verify

```bash
aws sts get-caller-identity
```

Expected output:
```json
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/ldcf-poc-deployer"
}
```

---

## Estimated Costs

| Component | Running | Paused |
|-----------|---------|--------|
| RDS MySQL t3.micro | ~$0.50/day | $0 (stopped) |
| Aurora Serverless v2 | ~$1-2/day | ~$0.05/day |
| DMS t3.micro | ~$0.80/day | $0 (stopped) |
| Lambda (free tier) | $0 | $0 |
| SQS (free tier) | $0 | $0 |
| DynamoDB (free tier) | $0 | $0 |
| S3 | < $0.10/day | $0 |
| **Total** | **~$3-5/day** | **~$0.10/day** |

Use `./cleanup.sh` to pause everything when not testing.
Use `./cleanup.sh --destroy-all` to delete everything when done.
