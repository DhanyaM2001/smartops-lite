# Grafana Cloud dashboard — SmartOps MTTR & Incidents

`mttr-dashboard.json` is a ready-to-import Grafana dashboard for the
Module 9 observability slice. It reads directly from CloudWatch and
CloudWatch Logs Insights — **no self-hosted Grafana, no Prometheus, no
Loki, no cost on AWS side beyond what's already accounted for.**

## What it shows

| Row       | Panel                                       | Source             |
|-----------|---------------------------------------------|--------------------|
| Headline  | Incidents (last 1 h)                         | `IncidentCount`         (CloudWatch metric) |
| Headline  | MTTR (avg)                                   | `MTTRSecondsAvg`        (CloudWatch metric) |
| Headline  | Ack rate                                     | `AckRatePercent`        (CloudWatch metric) |
| Headline  | LLM success rate                             | `LLMSuccessRatePercent` (CloudWatch metric) |
| Trends    | Incidents over time (total vs acknowledged) | `IncidentCount` + `AckedIncidentCount` |
| Trends    | MTTR rolling avg                             | `MTTRSecondsAvg`        (CloudWatch metric) |
| Breakouts | Top reasons (last 1 h)                       | **Logs Insights** query on `/aws/lambda/smartops-lite-rca-generator` |
| Breakouts | RCA source split (groq/fallback/none)        | **Logs Insights** query on same log group |

The 5 CloudWatch metrics are all no-dimension — that keeps us inside the
10-metric free-tier ceiling with 50 % headroom. Per-reason and
per-source breakouts run as ad-hoc **Logs Insights queries** against the
existing RCA Lambda log group, which is free within the 5 GB/mo
CloudWatch Logs ingest allowance.

## One-time Grafana Cloud setup (free tier)

1. Sign up at [grafana.com](https://grafana.com/products/cloud/) — the
   free tier is generous (10 k metric series, 50 GB logs) and needs no
   payment info.
2. In your stack → **Connections → Add new connection → CloudWatch**.
   - **Auth**: pick "Access & secret key" for the demo, or "Grafana
     Assume Role" once you're ready to wire OIDC (Module 8.1).
   - Create a dedicated IAM user (or role) in AWS whose only permissions
     are:
     ```json
     {
       "Statement": [
         {
           "Effect": "Allow",
           "Action": [
             "cloudwatch:ListMetrics",
             "cloudwatch:GetMetricData",
             "cloudwatch:GetMetricStatistics",
             "logs:StartQuery",
             "logs:StopQuery",
             "logs:GetQueryResults",
             "logs:GetLogEvents",
             "logs:DescribeLogGroups"
           ],
           "Resource": "*"
         }
       ]
     }
     ```
   - **Default region**: `ap-south-1` (must match Terraform `var.region`).
   - Save + test → Grafana will list every namespace in the account;
     confirm `SmartOps` shows up (may take up to 5 min after the first
     aggregator run publishes).

## Import the dashboard

1. Grafana Cloud UI → **Dashboards → New → Import**.
2. Paste the contents of `mttr-dashboard.json` OR upload the file.
3. When prompted for the **CloudWatch** data source, pick the one you
   created above (the dashboard uses the variable `${DS_CLOUDWATCH}`).
4. Optional: adjust the two textbox variables:
   - `namespace` — CloudWatch namespace (default `SmartOps`, matches
     `var.mttr_metric_namespace`).
   - `region` — AWS region (default `ap-south-1`, matches `var.region`).
5. **Save**.

## Verifying it works

After `terraform apply` + waiting one 5-min tick for the schedule to
fire the aggregator at least once:

- **CloudWatch console** → Metrics → All → `SmartOps` namespace → you
  should see the 5 metric names listed.
- **Grafana dashboard** → the four headline stat panels should show
  numbers (0 is fine if the incidents table is empty — that's the
  intentional zero-count sentinel).
- **Logs Insights panels** at the bottom stay empty until the first
  incident is processed. Trigger one via
  `make demo-crash` (see Module 4 runbook) to populate them.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| "No data" on every panel  | Aggregator hasn't run yet | Wait 5 min, or `make invoke-mttr` |
| Stat shows number, timeseries flat | Only one data point in range | Give the schedule a few more ticks |
| Logs Insights panels empty  | Log group name mismatch | Check the log group under panel JSON — it hard-codes `/aws/lambda/smartops-lite-rca-generator`; update if you renamed |
| Grafana says permission denied | IAM policy on the CW user is missing | Ensure the JSON above is attached |
| `SmartOps` namespace not listed | Aggregator IAM lacks `cloudwatch:PutMetricData` OR condition mismatch | Check `additional_policy_statements` in `main.tf`; namespace variable must match |

## Cost

At demo scale (a few incidents per day, 5-min schedule):

- **Grafana Cloud**: $0. Free tier covers everything on the dashboard.
- **AWS CloudWatch metrics**: $0. 5 series ≤ 10 free-tier ceiling.
- **AWS CloudWatch Logs Insights**: $0. Query scans on ~5 MB log group.
