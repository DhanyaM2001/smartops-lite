# ADR-000: Rejected project alternatives

**Status:** Accepted
**Date:** 2026-08-04
**Deciders:** dhanym

## Context

Before settling on SmartOps-Lite, 20 other project ideas were considered. This ADR archives the shortlist and the rationale for rejection, so a future reader (recruiter, agent, or the author months later) sees the *thought process*, not just the outcome.

## Decision

**Accepted:** SmartOps-Lite — GenAI-assisted K8s incident triage & auto-remediation.

## Alternatives considered (and why not chosen)

Scored on: **resume power** × **real-world relevance** × **career impact** × **feasibility in 20 days + free tier** × **uniqueness** × **learning depth**.

| # | Project | 1-line pitch | Why not chosen |
|---|---|---|---|
| 2 | **CertGuard** | Automated TLS cert & secret lifecycle on K8s | Strong candidate but narrower feature surface; kept as **stretch feature** in SmartOps |
| 3 | **CloudCostSense** | GenAI FinOps advisor dashboard | Pure AWS but zero K8s exposure; the project needed Kubernetes at its core |
| 4 | **LogLens** | Serverless log anomaly detection pipeline | Cheap and clean, but no K8s and no live "control loop" — feels more data-pipeline than DevOps |
| 5 | **LinkForge** | Multi-AZ URL shortener with chaos + observability | Classic system-design demo, but too "college project"-adjacent unless heavily elevated |
| 6 | **Chaos-in-a-Box** | Chaos engineering + AI incident report | Overlaps significantly with SmartOps; can be merged as scripts in this project |
| 7 | **BackupSentry** | Automated backup + DR verification | Unique but niche; harder to demo in 60 sec |
| 8 | **DeployPilot** | Blue-green + canary deploy platform | Merged INTO SmartOps as the CI/CD deployment layer |
| 9 | **ImageGuard** | Container vuln scanner + auto-remediator | Merged INTO SmartOps as Trivy in CI + Cosign signing |
| 10 | **DriftGuard** | K8s drift detector + auto-heal | Great idea but risks feature-creep; consider as follow-up |
| 11 | **PagerZero** | Intelligent alert deduplication | Merged INTO SmartOps' controller |
| 12 | **RunbookAI** | Slack chat → auto-generated runbook | Kept as **stretch feature** — write incidents from DynamoDB to a runbook repo |
| 13 | **RegionShift** | Multi-region active-passive failover | Tied at top of ranking but doubles infra costs & complexity — outside 20-day + free-tier budget |
| 14 | **APIMeter** | Multi-tenant API gateway w/ usage metering | Interesting SaaS angle but weak K8s + SRE story |
| 15 | **EdgeGuard** | CloudFront + WAF + Lambda@Edge auto-bot-block | Cool edge/security story but disconnected from author's background |
| 16 | **ServerlessOps** | Safe Lambda deploys (canary + auto-rollback) | Strong serverless story but no K8s |
| 17 | **CarbonSense** | Carbon-aware workload scheduler | Trendy but perceived as gimmicky; hard to demo real impact |
| 18 | **SBOM Guardian** | Software Bill of Materials + signing | Merged INTO SmartOps as Cosign in CI + Trivy SBOM |
| 19 | **QueueSage** | Async processing w/ auto-scale + DLQ recovery | Niche; less exciting to a recruiter |
| 20 | **SLOtracker** | SLO + error-budget dashboard | Tied at top; core concepts merged INTO SmartOps as the MTTR dashboard |
| 21 | **TelcoCloud5G** | Cloud-native 5G-style microservice + full DevOps | Too domain-specific; a general-purpose platform was chosen instead |

## Consequences

**Positive**
- We picked the option with the *highest weighted score* AND the *best skill-map coverage* to the author's target skill list.
- SmartOps absorbed the best ideas from 5 other candidates (DeployPilot, ImageGuard, PagerZero, SLOtracker, SBOM Guardian) — one coherent narrative instead of five thin ones.

**Negative**
- Higher complexity than picking a smaller project.
- Requires ~55 hrs; leaves less buffer than CloudCostSense would.

**Mitigations**
- Emergency plan in `docs/03-project-plan.md` (drop features in this order: cosign → GuardDuty → multi-node → Grafana dashboards → remediator).
- Weekly checkpoint gates in the plan.

## Alternatives archived for future

Options 2, 12, 13 are worthy of separate future projects. If SmartOps ships early or the author wants a second portfolio piece:
- **CertGuard** (2) — natural extension leveraging cert-manager work here
- **RunbookAI** (12) — a small Lambda + LLM add-on to this repo
- **RegionShift** (13) — a completely separate multi-region reliability story
