# SmartOps-Lite v1.0 — release notes

> **Draft.** This file becomes the GitHub Release description for tag `v1.0`.
>
> **Recorded run.** Deployed on a real AWS account, demoed, recorded and torn down on 23–25 Sep 2026.
>
> **Author.** Dhanya M.

---

## TL;DR

**Event-driven AIOps for Kubernetes on the AWS free tier.** When a pod crashes, a Kubernetes controller publishes the incident to EventBridge. A Lambda asks Groq's LLM for a two-sentence root cause, stores the incident in DynamoDB and posts a Slack card about 5 seconds after the crash. A second Lambda turns the incident table into CloudWatch metrics every 5 minutes.

- **159 tests passing** across 5 Python packages.
- **49 Terraform resources** from 8 reusable modules, `terraform validate` and `fmt -check` clean.
- **$0 billed** for the recorded run (AWS Free plan).

---

## What's included

### Infrastructure (Terraform 1.7.5)

- **Reusable modules:** `vpc`, `security-group`, `iam`, `k3s`, `ecr`, `eventbridge`, `dynamodb`, `lambda`.
- **Environment:** `infra/envs/dev/` with S3 remote state and a DynamoDB lock table (created once by `make bootstrap-backend`).
- **Compute:** 2 × `t3.micro` K3s cluster (server in `ap-south-1a`, agent in `ap-south-1b`), Ubuntu 24.04. The boot script installs K3s with unneeded add-ons disabled, adds swap, masks idle services, installs the ECR credential provider, and publishes the kubeconfig and join details to SSM.
- **No open ports.** `kubectl` reaches the API through an SSM Session Manager port-forward.

### Kubernetes workloads

- **`crashy-app`** — FastAPI demo service with failure endpoints (`/crash`, `/oom`, `/500`, `/slow`) and pod/node/zone identity headers. Helm chart with **hard** pod anti-affinity on `topology.kubernetes.io/zone`, so there's one replica per AZ.
- **`smartops-controller`** — Python controller (1 replica) that watches pods cluster-wide. It reports `CrashLoopBackOff`, image-pull errors, container create/run errors, `OOMKilled`, non-zero exits (`Error`) and failed pods, deduplicated on `(namespace, pod, container, reason)`, as `IncidentDetected` events (schema 1.0).

### Serverless

- **`rca-generator`** (256 MB / 60 s) — EventBridge-triggered. Validates the event, loads the Slack and Groq secrets from SSM once per cold start, asks Groq (`qwen/qwen3.8-27b`, 10 s timeout, 200 tokens) for a two-sentence RCA, writes the row to DynamoDB idempotently, and posts a Block Kit card. If Groq fails, the row and card still go out with fallback text.
- **`mttr-aggregator`** (128 MB / 30 s) — `rate(5 minutes)` schedule. Scans the last 60 minutes of incidents and publishes `IncidentCount`, `AckedIncidentCount`, `AckRatePercent`, `LLMSuccessRatePercent`, plus `MTTRSecondsAvg` once something has been acknowledged.
- **`remediator`** (256 MB / 10 s, Lambda Function URL) — receiver for the Slack "Acknowledge" button: HMAC-SHA256 check with a constant-time compare and a 5-minute replay window, then a conditional DynamoDB update. **Deployed and tested, but not connected to Slack in v1.0.**

### Observability

- **CloudWatch namespace `SmartOps`** — up to 5 no-dimension metrics, inside the 10-metric free allowance.
- **Lambda logs** in CloudWatch Logs with 14-day retention. Pod logs stay in the cluster (`kubectl logs`).
- **Optional Grafana Cloud dashboard** — `dashboards/grafana/mttr-dashboard.json`. Not set up in the recorded run.

### CI/CD

- **`ci.yml`** — `lint`, `validate` and `test` jobs that run the same `make` targets as a developer.
- **`security.yml`** — Trivy filesystem and IaC scans, plus a full-history Gitleaks scan, on push, PR and weekly.
- **`dependabot.yml`** — 9 entries: 5 Python packages, Terraform, 2 Dockerfiles and GitHub Actions.

### Documentation

- **`README.md`** — the project overview: problem, design, data flow, verified results, limitations.
- **`docs/INSTALL.md`** — the install-and-run guide, following the recorded run step by step, with every problem hit and its fix.
- **`docs/END-TO-END.md`** — architecture, sequence, IAM and routing diagrams (Mermaid).
- **`docs/REFERENCE.md`** — every `make` target and script, plus the change log.
- **`docs/adr/`** — 4 Architecture Decision Records: rejected alternatives, K3s vs EKS, AI backend, log pipeline.
- **`docs/modules/`** — 12 per-module runbooks.
- **`docs/06-cost-tracker.md`** — free-tier allowances per service.

---

## Numbers

| Metric | Value |
|---|---|
| **Tests passing** | **159** (crashy-app 8, controller 19, rca-generator 60, remediator 40, mttr-aggregator 32) |
| Terraform resources | 49 |
| Reusable Terraform modules | 8 |
| Lambda functions | 3 |
| CloudWatch metric series | up to 5 (4 in the recorded run, since nothing was acknowledged) |
| Crash → Slack card | about 5 s |
| AWS services *not* used, by design | EKS, NAT Gateway, load balancers, Secrets Manager, API Gateway |
| Billed for the recorded run | $0 |

---

## Design decisions worth calling out

1. **K3s on 2 × t3.micro, not EKS.** The EKS control plane alone is about $73/month. [ADR-001](adr/001-k3s-vs-eks.md)
2. **Groq's hosted LLM with fail-soft fallback.** Free at demo volume, OpenAI-compatible, called with stdlib `urllib`. The model is a Terraform variable, so when Groq retired `llama-3.3-70b-versatile` mid-project, switching to `qwen/qwen3.8-27b` changed one default and no code. [ADR-002](adr/002-ai-backend-choice.md)
3. **Node IAM role, not IRSA.** IRSA on K3s needs a self-hosted OIDC issuer and per-service-account trust. The node role is scoped per ARN, with the trade-off documented in the README's security section. [Module 4 runbook](modules/04-controller.md)
4. **Aggregator Lambda + CloudWatch, not Prometheus.** Prometheus would need about 300 MB of a 1 GB node. [Module 9 runbook](modules/09-observability.md)

---

## Not in v1.0

- **Slack Acknowledge button wiring.** Needs the signing secret in SSM and the Slack app's Interactivity URL; steps are in [`modules/07-remediator.md`](modules/07-remediator.md).
- **Automatic remediation (Module 7.1).** The remediator can emit `RemediationRequested`, but nothing consumes it yet.
- **Log shipping (Module 5.1).** Skipped; the RCA works from pod metadata. See [ADR-003](adr/003-log-pipeline-choice.md).
- **Release pipeline with GitHub OIDC (Module 8.1).** Deferred.

The README's "Known limitations" section lists the rest, including the false `PodFailed` alerts from `make demo-reset`.

---

## Upgrade path to a production candidate

1. **K3s → EKS** (or another managed control plane) once the budget allows.
2. **Per-pod IAM.** Publish the cluster's service-account OIDC issuer and give the controller its own role; narrow the node role to ECR pulls and the K3s parameters.
3. **DynamoDB Scan → Query** with a GSI on `ingestedAt` once incident volume grows.
4. **Dead-letter queue and alarms** on the RCA Lambda.
5. **A second LLM provider** as a fallback behind the same prompt.

---

## Tagging and publishing (checklist)

Run these in the dev container once the repo is on GitHub:

```bash
make lint && make validate && make test
```

```bash
git tag -a v1.0 -m "SmartOps-Lite v1.0" && git push origin v1.0
```

```bash
gh release create v1.0 --title "SmartOps-Lite v1.0 — AIOps for Kubernetes on the AWS free tier" --notes-file docs/12-release-notes-v1.0.md --latest
```

---

## Acknowledgements

- **Groq** for a free tier that works at demo volume.
- **K3s** for making multi-node Kubernetes runnable on t3.micro.
- **moto** for hermetic AWS mocking in the tests.
