# MTTR Aggregator (Module 9.0)

Scheduled Lambda that turns the raw `smartops-incidents` DynamoDB table into
production-shape CloudWatch metrics for the Grafana dashboard — **entirely
inside the AWS free tier at demo scale.**

## Flow

```
    EventBridge schedule (rate: 5 min)
                │
                ▼
    ┌───────────────────────┐
    │  mttr-aggregator      │
    │  Lambda (Python 3.12) │
    └───────────────────────┘
       │            │
       ▼            ▼
    DDB Scan     CloudWatch PutMetricData
    (incidents)  (namespace: SmartOps)
                     │
                     ▼
              Grafana Cloud
              (CloudWatch DS)
```

## Metrics emitted (namespace `SmartOps`)

Exactly **5 no-dimension metric series** — sized to fit inside CloudWatch's
10-metric free tier ceiling with 100 % headroom.

| Metric                   | Unit    | Meaning                                             |
|--------------------------|---------|-----------------------------------------------------|
| `IncidentCount`          | Count   | Total incidents in the window (default 60 min)      |
| `AckedIncidentCount`     | Count   | Total acknowledged incidents in the window          |
| `AckRatePercent`         | Percent | 100 × acked / total                                 |
| `LLMSuccessRatePercent`  | Percent | 100 × (`rcaSource == "groq"`) / total               |
| `MTTRSecondsAvg`         | Seconds | Avg (`acknowledgedAt` − `ingestedAt`), acked rows only |

### Why no dimensions?

CloudWatch charges $0.30/mo for each **unique** (metric_name, dimension_set)
series above 10. `IncidentCount{Reason=CrashLoopBackOff}` and
`IncidentCount{Reason=OOMKilled}` are two distinct series, so a per-reason
breakout across ~10 possible reasons would blow the budget.

**Per-reason and per-source breakouts still appear on the dashboard**, but
they come from **CloudWatch Logs Insights queries** against the existing
`/aws/lambda/smartops-rca-generator` log group. Logs Insights is free
within the 5 GB/mo Logs ingest allowance, which our demo scale doesn't
approach. See `dashboards/grafana/README.md` for the queries.

### Row eligibility for MTTR

Rows without BOTH `ingestedAt` AND `acknowledgedAt` are counted in
`IncidentCount` but excluded from `MTTRSecondsAvg` — they'd bias averages
toward the window boundary. Rows with `acknowledgedAt` before `ingestedAt`
(clock skew) are silently dropped from MTTR.

## Env vars

| Var                     | Required | Default      | Purpose                            |
|-------------------------|----------|--------------|------------------------------------|
| `INCIDENTS_TABLE_NAME`  | Yes      | —            | DDB table to scan                  |
| `METRIC_NAMESPACE`      | No       | `SmartOps`   | CloudWatch namespace               |
| `WINDOW_MINUTES`        | No       | `60`         | How far back to look each run      |
| `LOG_LEVEL`             | No       | `INFO`       | stdlib logging level               |
| `AWS_REGION`            | No       | `ap-south-1` | boto3 client region                |

No secrets — IAM only needs `dynamodb:Scan` on the incidents table ARN +
`cloudwatch:PutMetricData` on the SmartOps namespace.

## AWS free-tier compliance

| Service    | Free tier              | This Lambda's usage             | Cost |
|------------|-----------------------|---------------------------------|------|
| Lambda invocations | 1M req/mo    | 12/hr × 24 × 30 = **8,640/mo** | $0 |
| Lambda compute     | 400k GB-s/mo | 128 MB × 300 ms × 8,640 ≈ 332 GB-s | $0 |
| CloudWatch metrics | 10 series/mo | **5 series** — 50 % headroom   | $0 |
| CloudWatch logs    | 5 GB/mo      | ~5 MB/mo (5 log lines × 8,640) | $0 |
| DDB Scan RCU       | 25 RCU on-demand | Full scan on ~100 rows × 12/hr | $0 |

**Total marginal cost of Module 9: $0/mo at demo scale.**

## Testing

```bash
cd lambdas/mttr-aggregator
poetry install --with dev --no-root
poetry run pytest -q
```

Every test uses `moto` for DDB + CloudWatch — zero live-AWS calls, zero network.
