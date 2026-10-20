# Module 9 — MTTR Aggregator + Grafana Dashboard

> **Build-time runbook.** Written while this module was built, before the first real AWS run. For the tested steps, use [`docs/INSTALL.md`](../INSTALL.md); where the two differ, INSTALL wins. In the recorded run the aggregator published 4 metrics (`MTTRSecondsAvg` needs an acknowledged incident) and the Grafana dashboard wasn't set up.

> **Scope.** A scheduled Lambda that scans the incidents table every 5 min, computes five headline SRE metrics, and publishes them to CloudWatch. A Grafana Cloud dashboard reads them plus two CloudWatch Logs Insights queries for per-reason breakouts.
>
> **Goal.** Show that the pipeline works — recruiters see IncidentCount, MTTR, AckRate, and LLMSuccessRate trend lines in one screenshot.
>
> **Cost.** $0/mo. Every service is free-tier compliant at demo scale (details in §6).

---

## 1. Why an aggregator (Option D) — three alternatives were rejected

| Option | Rejected because |
|--------|------------------|
| A. Self-hosted Prometheus/Grafana on K3s | t3.micro nodes have ~1 GB RAM; Prometheus + Grafana eats 400-600 MB → tight, no headroom for the app. |
| B. Grafana Cloud with Prometheus remote-write | Adds an in-cluster exporter (`node_exporter` etc.) + auth wiring. Complexity ≥ value at demo scale. |
| C. Direct dashboard queries against DynamoDB | Grafana has no DDB data source; would need a proxy Lambda per query. |
| **D. Lightweight Lambda → CloudWatch metrics → Grafana Cloud (CloudWatch DS)** ✅ | Decouples metric computation from storage. Future: swap CloudWatch → Prometheus → Datadog without touching aggregator. Everything free-tier. |

The aggregator is a **pure business-logic function** with an I/O shim (DDB scan + CloudWatch put). This mirrors the RCA Lambda's shape — same testing pattern, same cold-start pattern — so the reviewer sees a consistent architecture.

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ EventBridge Scheduler — rate(5 minutes)                         │
└─────────────────────────────────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Lambda: smartops-lite-mttr-aggregator (Python 3.12, 128 MB)     │
│ ┌───────────────┐  ┌──────────────┐  ┌────────────────────────┐ │
│ │ ddb_reader    │→ │ aggregator   │→ │ publisher              │ │
│ │ (Scan +       │  │ (pure logic, │  │ (batched               │ │
│ │  unmarshall)  │  │  no I/O)     │  │  PutMetricData)        │ │
│ └───────────────┘  └──────────────┘  └────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
     │                    │                        │
     ▼                    │                        ▼
┌──────────────┐          │             ┌───────────────────────┐
│ DynamoDB     │          │             │ CloudWatch Metrics    │
│ smartops-    │          │             │ namespace: SmartOps   │
│ incidents    │          │             │ 5 no-dim series       │
└──────────────┘          │             └───────────────────────┘
                          │                        │
                          │                        ▼
                          │             ┌───────────────────────┐
                          │             │ Grafana Cloud         │
                          │             │ (CloudWatch data src) │
                          │             │ 8 panels              │
                          │             └───────────────────────┘
                          │                        ▲
                          ▼                        │
              ┌────────────────────────────────────┴───┐
              │ CloudWatch Logs Insights (free within  │
              │ 5 GB/mo ingest) — feeds 2 breakout     │
              │ panels from the RCA Lambda log group.  │
              └────────────────────────────────────────┘
```

---

## 3. Metrics emitted (namespace `SmartOps`)

Exactly **5 no-dimension series** — sized so we stay inside CloudWatch's 10-metric free tier with 50 % headroom.

| Metric                   | Unit    | Meaning                                             |
|--------------------------|---------|-----------------------------------------------------|
| `IncidentCount`          | Count   | Total incidents in the window (default 60 min).     |
| `AckedIncidentCount`     | Count   | Total incidents where `acknowledgedAt` is present.  |
| `AckRatePercent`         | Percent | 100 × acked / total.                                |
| `LLMSuccessRatePercent`  | Percent | 100 × (`rcaSource == "groq"`) / total.              |
| `MTTRSecondsAvg`         | Seconds | Avg (`acknowledgedAt` − `ingestedAt`), acked rows only. |

### Why no dimensions?

Every unique `(metric_name, dimension_set)` counts as its own series against the 10-metric ceiling. `IncidentCount{Reason=CrashLoopBackOff}` and `IncidentCount{Reason=OOMKilled}` are **two** series. With ~10 possible reasons, per-reason breakouts alone could blow the budget.

Per-reason and per-source breakouts are **still on the dashboard** — they come from **CloudWatch Logs Insights** queries against the `/aws/lambda/smartops-lite-rca-generator` log group. Logs Insights charges $0.005 per GB scanned; our RCA Lambda emits ~5 MB/mo so it's practically free.

### MTTR row eligibility

Only rows with **both** `ingestedAt` AND `acknowledgedAt` contribute to `MTTRSecondsAvg`. Unacknowledged rows are still in `IncidentCount` but excluded from MTTR — including them would bias the average toward the window boundary. Rows where `acknowledgedAt < ingestedAt` (clock skew) are silently dropped.

---

## 4. Code layout

```
lambdas/mttr-aggregator/
├── pyproject.toml                        Poetry project (dev-only deps)
├── README.md                             Runbook for operators
├── src/mttr_aggregator/
│   ├── __init__.py                       Module docstring
│   ├── config.py                         Cold-start-only env-var load
│   ├── ddb_reader.py                     Scan + unmarshall
│   ├── aggregator.py                     Pure logic, no I/O
│   ├── publisher.py                      CloudWatch PutMetricData batching
│   └── handler.py                        Lambda entry point (event.time)
└── tests/
    ├── conftest.py                       moto fixtures, row factory
    ├── test_aggregator.py                15 tests, pure logic
    ├── test_ddb_reader.py                 5 tests, unmarshall + window
    ├── test_publisher.py                  6 tests, batching + soft-fail
    └── test_handler.py                    6 tests, end-to-end with moto

Total: 32 tests, all hermetic (moto DDB + CloudWatch, no live AWS).
```

### Cold-start-only init pattern

Same as the RCA Lambda (see [`05-rca-lambda.md`](./05-rca-lambda.md) §5):

```python
_CONFIG: Config | None = None
_DDB: Any = None
_CW: Any = None

def _init() -> tuple[Config, Any, Any]:
    global _CONFIG, _DDB, _CW
    if _CONFIG is None:
        _CONFIG = Config.from_env()
    if _DDB is None:
        _DDB = boto3.client("dynamodb", region_name=_CONFIG.aws_region)
    if _CW is None:
        _CW = boto3.client("cloudwatch", region_name=_CONFIG.aws_region)
    return _CONFIG, _DDB, _CW
```

### Event-time trick

Handler reads `event["time"]` (EventBridge always sets this to the schedule tick's ISO timestamp) rather than `datetime.now(...)`. Two benefits:

1. **Deterministic aggregation windows** aligned to the schedule tick.
2. **Trivial testability** — pytest passes `{"time": "2026-08-26T12:00:00Z"}` and every downstream `now` reference lines up with the seeded row timestamps in `conftest.py`.

Falls back to wall clock if the field is missing or unparseable (e.g. manual `aws lambda invoke` with an empty payload).

---

## 5. Terraform wiring

Three resources (plus one reusable Lambda module invocation):

```hcl
module "lambda_mttr_aggregator" { source = "../../modules/lambda"; ... }

resource "aws_cloudwatch_event_rule" "mttr_schedule" {
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "mttr_lambda" { ... }
resource "aws_lambda_permission"      "eventbridge_invoke_mttr" { ... }
```

### IAM (least-privilege)

| Action                       | Resource                          | Condition                              |
|------------------------------|-----------------------------------|----------------------------------------|
| `dynamodb:Scan`              | incidents table ARN               | —                                      |
| `cloudwatch:PutMetricData`   | `*` (API doesn't accept ARNs)     | `cloudwatch:namespace = SmartOps`      |

The `cloudwatch:namespace` condition is the enforcement gate: even though the Resource has to be `*` (CloudWatch's API doesn't accept metric-level ARNs), the condition locks the Lambda to publishing ONLY into the SmartOps namespace.

---

## 6. Free-tier compliance (per §7's numbers)

| Service | Free tier | Module 9 usage | Cost |
|---------|-----------|----------------|------|
| Lambda invocations | 1M req/mo | 12/hr × 720 h = **8,640** | $0 |
| Lambda compute | 400k GB-s/mo | 128 MB × 300 ms × 8,640 = **332 GB-s** | $0 |
| CloudWatch custom metrics | 10 series | **5 series** (50 % headroom) | $0 |
| CloudWatch Logs ingest | 5 GB/mo | ~5 MB/mo (Lambda logs) | $0 |
| CloudWatch Logs Insights | $0.005/GB scanned | ~5 MB × 12 queries/hr ≈ 43 MB/mo | $0 |
| DDB Scan on-demand | 25 RCU | ~100 rows × 12/hr = ~1200 RCU/mo | $0 |
| EventBridge scheduled events | $1/1M | 8,640/mo | $0 |

**Total marginal cost of Module 9: $0/mo at demo scale.**

---

## 7. Grafana Cloud setup

See [`dashboards/grafana/README.md`](../../dashboards/grafana/README.md) for the full setup runbook:

1. Sign up for Grafana Cloud (free tier).
2. Add a CloudWatch data source using an IAM user scoped to `cloudwatch:*`, `logs:StartQuery`, `logs:GetQueryResults`.
3. Import `dashboards/grafana/mttr-dashboard.json`.
4. Wait 5 min for the first schedule tick to populate metrics.

---

## 8. Local runbook

### Run tests

```bash
cd lambdas/mttr-aggregator
poetry install --with dev --no-root
poetry run pytest -q
# → 32 passed
```

### Deploy

```bash
make tf-apply     # rebuilds Module 9 Lambda + schedule rule
make invoke-mttr  # fire the aggregator now (bypass 5-min schedule)
make logs-mttr-aggregator  # tail its logs
```

### Verify metrics landed

```bash
make cloudwatch-metrics-mttr
# Expected: 5 rows (IncidentCount, AckedIncidentCount, AckRatePercent,
#           LLMSuccessRatePercent, MTTRSecondsAvg)
```

### Rebuild the dashboard from scratch

If you edit `dashboards/grafana/mttr-dashboard.json`:

1. Grafana → Dashboards → open MTTR dashboard → JSON model → paste new JSON.
2. Or re-import: Dashboards → New → Import → paste, keep same UID (`smartops-mttr-v1`) to overwrite.

---

## 9. Design decisions worth calling out

### 9.1 Why scan, not query?

At demo scale (~100 rows), a full Scan every 5 min costs ~5 RCU per run — well under the 25 RCU/s on-demand free tier limit. Adding a GSI on `ingestedAt` for Query would add complexity + a second table's worth of write capacity for negligible benefit. If the table ever exceeded ~10 k rows, we'd flip to a GSI + Query pattern; the aggregator is written so this swap is 20 lines in `ddb_reader.py`.

### 9.2 Why fail-soft on CloudWatch, fail-loud on DDB?

- **DDB Scan failure** = we can't compute the metrics at all. Raise → EventBridge retries on next tick. The bad tick is skipped; the next tick catches up.
- **CloudWatch PutMetricData failure** = one tick of metrics is missing. Log a warning, swallow the exception. The next tick will re-emit fresh values; nothing is lost forever.

This mirrors the RCA Lambda's fail-loud/soft split (DDB errors bubble; Slack errors don't block persistence).

### 9.3 Why 60-min default window?

- **Long enough** that ack-rate and MTTR have statistical meaning.
- **Short enough** that Grafana refreshes look "live" — a stale incident from 3 h ago doesn't dominate the average.
- Config knob (`WINDOW_MINUTES`) lets you tune per-env.

### 9.4 Why per-reason lives in Logs Insights, not CloudWatch metrics?

Two reasons:

1. **Free-tier ceiling** — see §3.
2. **Flexibility** — Logs Insights queries can be rewritten in the Grafana panel JSON without a Terraform apply. Per-reason CloudWatch metrics would require the aggregator to know every possible reason at code time, which contradicts the K8s "reason is free-text" reality.

---

## 10. What's NOT in Module 9 (deferred)

- **Alerting**: Grafana Cloud alerts on ack-rate < 50 % or MTTR > 10 min. Would land in a later "reliability polish" module; the metrics are already there.
- **SLO/burn-rate math**: turning `IncidentCount` + `MTTRSecondsAvg` into an availability SLO with an error budget. Adds ~50 lines of aggregator code; deferred until there's a demo need.
- **Per-namespace or per-node breakouts**: same story — Logs Insights queries can add these on-demand without a code change.

---

## 11. Change-log

| Date | Change |
|------|--------|
| 2026-08-26 | Initial ship: 5 metrics, 5-min schedule, Grafana dashboard, 32 tests, $0/mo. |
| 2026-08-26 | Fixed pre-existing Terraform bug: `lambda` module's `additional_policy_statements.Resource` type unified to `list(string)`; RCA + remediator callers updated. |
| 2026-08-26 | Shrunk `var.root_volume_gb` default 20 → 15 GB so 2-node cluster fits the 30 GB EBS free-tier ceiling. |
