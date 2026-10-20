# ADR-003: Log pipeline — Fluent Bit → CloudWatch → S3

**Status:** Accepted
**Date:** 2026-08-04
**Deciders:** dhanym

## Context

Every K8s pod's stdout/stderr must be:

- Collected reliably (with metadata: pod, namespace, node, container).
- Queryable within seconds by the RCA Lambda.
- Retained for at least 7 days (for debugging) and archived cheaply for 30 days.

Common options: Fluent Bit, Fluentd, Vector, Loki, Filebeat, native CloudWatch agent, Promtail.

## Decision

**Fluent Bit** (DaemonSet on K3s) → **CloudWatch Logs** (7-day retention) → **S3** (30-day, then Glacier, then delete).

## Rationale

### Why Fluent Bit (over Fluentd, Vector, Filebeat, Promtail)

- **C-based, tiny footprint** (~25 MB memory) — critical on t3.micro nodes (900 MB total RAM after K3s overhead).
- **Direct author familiarity** — the author has hands-on Fluent Bit experience; this project applies it in a cloud-native context.
- Native **CloudWatch output plugin** (no bridge/adapter).
- CNCF graduated project → recruiter-recognisable.

**Rejected:**
- **Fluentd:** heavier (Ruby-based, ~100 MB), overkill.
- **Vector:** newer, less industry-adopted (though excellent tech).
- **Filebeat / Logstash (ELK):** additional infra (Elasticsearch is expensive; free tier limited).
- **Promtail → Loki:** great combo, but Loki requires an object store and its own service; also duplicates what CloudWatch gives us for free.
- **Native CloudWatch agent:** less K8s-aware; less flexible filters.

### Why CloudWatch Logs (over Loki, OpenSearch)

- Free tier: **5 GB ingestion + 5 GB storage per month** forever.
- CloudWatch Logs Insights lets the RCA Lambda run a **SQL-like query** over recent logs in ~1 second — critical for the "last 2 min of logs" fetch.
- **AWS-native** — matches the resume story.
- Zero infrastructure to run (unlike Loki, which needs its own pod + object store).

**Rejected:**
- **OpenSearch:** no free tier for serverless; managed cluster costs $$$.
- **Loki:** great but is another service to manage; free-tier constraint favours CloudWatch.

### Why S3 for archive

- **CloudWatch retention costs money after free tier** (~$0.03/GB/month archived).
- Exporting to S3 nightly + lifecycle rule → Glacier at 30 days → delete at 90 days.
- Long-tail forensic use case (e.g. "what happened 45 days ago") is available if needed.
- Athena can query S3 directly for ad-hoc SQL over old logs.

### Data flow

```
container stdout/stderr
  ↓  (containerd captures to /var/log/containers/*.log)
Fluent Bit DaemonSet (tail + enrich with K8s metadata)
  ↓  (CloudWatch output plugin, IRSA-based auth)
CloudWatch Logs group: /aws/smartops/pods
  stream: <namespace>/<pod>/<container>
  retention: 7 days
  ↓  (Lambda subscription filter, or export task nightly)
S3 bucket: smartops-log-archive
  lifecycle: 30d → Glacier → delete at 90d
```

## Consequences

### Positive
- AWS-native, free-tier-friendly, resume-friendly.
- Author's prior Fluent Bit experience translates directly.
- CloudWatch Logs Insights = fast queries for RCA Lambda.

### Negative
- CloudWatch cost model can bite if a runaway pod generates GB/hour — need log-rate alerts.
- No unified metrics-and-logs query (like Loki + Prometheus via LogQL) — but Grafana handles this by pointing at multiple datasources.

### Mitigations
- Fluent Bit filter: drop logs matching `.level=DEBUG` and system-noise patterns before shipping.
- CloudWatch metric filter: alert if any pod's log rate > 10 MB/min.
- If free tier is being consumed too fast: reduce retention to 3 days.

## Fluent Bit config sketch

```yaml
# helm/observability/values-fluentbit.yaml (excerpt)
inputs: |
  [INPUT]
    Name              tail
    Path              /var/log/containers/*.log
    Parser            docker
    Tag               kube.*
    Refresh_Interval  5

filters: |
  [FILTER]
    Name                kubernetes
    Match               kube.*
    Merge_Log           On
    Keep_Log            Off
    K8S-Logging.Parser  On

  [FILTER]
    Name   grep
    Match  kube.*
    Exclude log ^.*level=DEBUG.*$

outputs: |
  [OUTPUT]
    Name                cloudwatch_logs
    Match               kube.*
    region              ap-south-1
    log_group_name      /aws/smartops/pods
    log_stream_prefix   $(kubernetes['namespace_name'])/$(kubernetes['pod_name'])/
    auto_create_group   On
    log_retention_days  7
```

## References

- [Fluent Bit docs](https://docs.fluentbit.io/)
- [CloudWatch Logs pricing](https://aws.amazon.com/cloudwatch/pricing/)
