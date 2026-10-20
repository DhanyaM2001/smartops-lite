# SmartOps-Lite — Diagram Sources

All diagrams are [Mermaid](https://mermaid.js.org/) source. GitHub renders them natively when viewed inline (see [`docs/END-TO-END.md`](../END-TO-END.md)). For PNG exports (LinkedIn, slides, etc.), use `mmdc` locally or [mermaid.live](https://mermaid.live/).

## Catalog

| # | File | Section in [END-TO-END.md](../END-TO-END.md) | Type |
|---|---|---|---|
| 1 | [`system-context.mmd`](system-context.mmd) | §1 — one-slide hero view | flowchart LR |
| 2 | [`architecture.mmd`](architecture.mmd) | §2 — master component diagram | flowchart LR |
| 3 | [`deployment-topology.mmd`](deployment-topology.mmd) | §3 — VPC / AZs / serverless / managed | flowchart TB |
| 4 | [`sequence-happy-path.mmd`](sequence-happy-path.mmd) | §4.1 — GET /crash → Slack card | sequenceDiagram |
| 5 | [`sequence-ack-path.mmd`](sequence-ack-path.mmd) | §4.2 — Slack Ack → DDB update (optional path) | sequenceDiagram |
| 6 | [`sequence-aggregator.mmd`](sequence-aggregator.mmd) | §4.3 — 5-min tick → CloudWatch (→ optional Grafana) | sequenceDiagram |
| 7 | [`sequence-cold-start.mmd`](sequence-cold-start.mmd) | §4.4 — SSM/KMS secrets flow | sequenceDiagram |
| 8 | [`state-incident-lifecycle.mmd`](state-incident-lifecycle.mmd) | §5.1 — DDB row state machine | stateDiagram-v2 |
| 9 | [`eventbridge-routing.mmd`](eventbridge-routing.mmd) | §8 — bus rules + targets | flowchart LR |
| 10 | [`iam-permission-graph.mmd`](iam-permission-graph.mmd) | §7 — principals × resources | flowchart LR |
| 11 | [`module-dependency.mmd`](module-dependency.mmd) | §9 — 13-module DAG | flowchart TB |

## Rendering to PNG

**Option A — local `mmdc`:**
```bash
npm install -g @mermaid-js/mermaid-cli

# Single file
npx -y @mermaid-js/mermaid-cli \
    -i docs/diagrams/architecture.mmd \
    -o docs/img/architecture.png \
    -w 1600 -H 900 --theme dark

# Batch (bash)
for f in docs/diagrams/*.mmd; do
    out="docs/img/$(basename "$f" .mmd).png"
    npx -y @mermaid-js/mermaid-cli -i "$f" -o "$out" -w 1600 -H 900 --theme dark
done
```

**Option B — web:**
1. Open [mermaid.live](https://mermaid.live/).
2. Paste the file contents (skip the `%% ...` comment headers).
3. Actions → PNG → save to `docs/img/<name>.png`.

## Color legend (used consistently)

| Class | Fill | Stroke | Meaning |
|---|---|---|---|
| `actor` | `#fff8dc` | `#c8a417` | Human (developer, engineer) |
| `pod` | `#e6f2ff` | `#2563eb` | K8s pod / on-cluster component |
| `lambda` | `#fef3c7` | `#d97706` | AWS Lambda function |
| `bus` | `#f3e8ff` | `#7c3aed` | Event router (EventBridge) |
| `store` | `#ecfdf5` | `#059669` | Data store (DDB, CW, S3, ECR) |
| `secret` | `#fee2e2` | `#dc2626` | Secret store / KMS-encrypted |
| `ext` | `#f5f5f5` | `#525252` | External service (Slack, Groq, Grafana) |
| `fnurl` | `#fef3c7` dashed | `#d97706` | Lambda Function URL (dashed border) |
| `ci` | `#e0e7ff` | `#4f46e5` | CI/CD (GitHub Actions) |
| `setup` | `#fef3c7` | `#d97706` | Setup module (module dep graph) |
| `infra` | `#e6f2ff` | `#2563eb` | Infrastructure module |
| `optional` | `#f3e8ff` dashed | `#7c3aed` | Optional module |
| `polish` | `#ecfdf5` | `#059669` | Docs/polish module |

## Editing rules

1. **Never edit generated PNGs directly.** Edit the `.mmd`, then re-render.
2. **Keep node labels short** (≤ 4 lines). If a description is longer, put it in the surrounding prose in `END-TO-END.md`.
3. **Stay in the color palette above.** Every reviewer's eye now knows what red = secret, blue = pod, etc.
4. **When adding a new diagram**, update this README's catalog + link it from `END-TO-END.md`.
