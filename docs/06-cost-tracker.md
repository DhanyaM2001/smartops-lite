# Cost Tracker — SmartOps-Lite

**Target:** $0 AWS spend.
**Billing guard:** the AWS Free plan (usage draws from credits, never the card) plus an optional zero-spend budget you create by hand ([`INSTALL.md` §1.1](INSTALL.md#11-aws-account-and-cli-user)). No script creates a billing alarm.
**Region:** ap-south-1 (Mumbai).

---

## Outcome of the recorded run

| Item | Value |
|---|---|
| Modules built | 2026-08-04 → 2026-08-26 |
| First real AWS run | 2026-09-23 → 2026-09-25 (deploy, debug, demo, recording) |
| Account | New account on the AWS **Free plan** |
| **Billed** | **$0** |
| Teardown | `make eod`; `check-orphans.sh` reported no orphaned billable resources |
| Paid API calls avoided | Cost Explorer (`make cost`, `make cost-by-service`, `make status`, `SHOW_COST=true make demo`) — $0.01 per call |

---

## Per-service breakdown expectations

If any of these show spend, investigate:

| Service | Expected | Alarm if > |
|---|---|---|
| EC2 – Compute | $0 (free tier) | $0.50 |
| EC2 – Data transfer | $0 (in-region) | $0.20 |
| Lambda | $0 (1M req free) | $0.10 |
| S3 | $0 (< 5 GB) | $0.10 |
| DynamoDB | $0 (< 25 GB, on-demand) | $0.10 |
| CloudWatch Logs | $0 (< 5 GB) | $0.20 |
| ECR | $0 (< 500 MB) | $0.10 |
| EventBridge | $0 (< 1M) | $0.05 |
| **Cost Explorer API** | $0 (don't call it) | $0.01 per call |
| **NAT Gateway** | $0 (not used) | any $ = misconfig |
| **ALB** | $0 (not used) | any $ = misconfig |
| **EKS** | $0 (not used) | any $ = misconfig |
| **Secrets Manager** | $0 (using SSM instead) | any $ = misconfig |

---

## Free-tier compliance audit (as of Module 9)

Every service the project provisions is sized to fit inside AWS's Always
Free or 12-month Free Tier limits, PROVIDED you run `make eod` between
sessions. Numbers below assume a typical week (2 hours of hands-on demo
work per day) and are conservative — real usage is lower.

| Service | Free tier limit | Actual usage | Status |
|---|---|---|---|
| **EC2** (2 × t3.micro) | 750 h/mo (single) | 2 nodes × ~2 h/day × 30 = **120 h** | ✅ well under with `make eod` |
| **EBS gp3** | 30 GB total | 2 × **15 GB** = 30 GB (Module 9 shrink) | ✅ at ceiling |
| **DynamoDB** on-demand | 25 GB storage + 25 RCU/WCU | <1 MB, ~1200 ops/hr peak | ✅ |
| **Lambda** (all 3 fns) | 1M req + 400k GB-s | ~10 k req/mo, ~500 GB-s/mo | ✅ |
| **EventBridge** custom events | $1/M events | ~100/mo (M4 controller) + 8,640/mo (M9 schedule) | ✅ (paid threshold not reached) |
| **CloudWatch** custom metrics | 10 series | **up to 5 series** (4 in the recorded run) | ✅ 50 % headroom |
| **CloudWatch Logs** ingest + storage | 5 GB / 5 GB | <100 MB/mo across all Lambdas | ✅ |
| **CloudWatch Logs Insights** | $0.005/GB scanned | only if you run queries (e.g. the optional Grafana breakout panels) | ✅ effectively $0 |
| **S3** | 5 GB + 20 k GET + 2 k PUT | ~1 MB tf-state, <100 requests/mo | ✅ |
| **SSM** Parameter Store standard | Unlimited standard params | 2 secrets (+1 optional) + 4 written by K3s | ✅ |
| **KMS** | 20 k requests | ~100/mo | ✅ |
| **ECR** private | 500 MB | 2 images × ~150 MB | ✅ |
| **Lambda Function URL** | Free | 1 URL (Module 7 remediator) | ✅ |
| **VPC / IGW / SG** | Free | 1 VPC, 2 public subnets, no NAT | ✅ |
| **NAT Gateway / NLB / ALB / EKS** | **Paid** | **Not used** (by design) | ✅ |

**Bottom-line expected monthly cost at demo scale: $0.00.**

**Discipline required to keep it $0:**

1. `make eod` at the end of every session — takes cluster from 2 nodes → 0 nodes → tf-state only.
2. Never enable NAT Gateway, ALB, EKS, or Secrets Manager.
3. Don't leave the `mttr_metric_namespace` variable pointed at anything other than `SmartOps` — the IAM policy is gated on that exact value.
4. If the cluster runs for more than ~375 hours in a month (2 nodes), EC2 free-tier hours may exceed 750. Watch the **Billing console**, which is free; `make cost` shows the same thing but each call costs $0.01.
5. Don't call the Cost Explorer API (`make cost`, `make cost-by-service`, `make status`, `SHOW_COST=true make demo`) if you need a strict $0.

---

## References

- [AWS Free Tier](https://aws.amazon.com/free/) — check current limits before adding services
- `docs/adr/002-ai-backend-choice.md` — why Groq default (cost driver)
- `docs/adr/001-k3s-vs-eks.md` — why K3s (biggest cost saver — saves ~$73/mo)
