# Module 11 — README polish + architecture diagram + Loom video script

> **Build-time record.** Written while this module was built. The README has since been rewritten around the recorded AWS run, and the Loom script, marketing notes and `PROJECT_CONTEXT.md` mentioned below are kept outside the public repo.

> **Scope.** Turn the repo's front door into the recruiter-facing narrative. Rewrite `README.md` around a hero image + four design decisions, ship an editable Mermaid architecture diagram, and produce a word-for-word Loom recording script.
>
> **Goal.** A recruiter spending 30 seconds on the GitHub tab and 90 seconds on the Loom link comes away understanding what was built, why, and that it works.
>
> **Cost.** $0/mo. Docs + Mermaid + one Loom recording.

---

## 1. What was wrong with the old README

- **Stale status** — "Modules 0-8.0 complete", but 9 + 10 shipped since.
- **Fabricated architecture** — old ASCII diagram named `fluent-bit` and `prometheus + grafana`, neither of which is in the codebase. `fluent-bit` was explicitly rejected in Module 6; observability moved to a Lambda + CloudWatch + Grafana Cloud path in Module 9. Repeating what the code doesn't do is worse than showing no diagram.
- **No design-decision anchor** — a 30-second recruiter skim had no way to see that K3s-not-EKS, Groq-not-Bedrock, and node-IAM-not-IRSA were *deliberate* choices with rejected alternatives.
- **No hero image** — jumped straight from title to prose. First screen was a wall of text.
- **`make demo` marked "available after Module 10"** — a lie that's now safe to remove.
- **Repo tree missed 4 subtrees** — `apps/crashy-app/`, `lambdas/mttr-aggregator/`, `dashboards/grafana/`, `docs/diagrams/`.
- **Skills list had `Fluent Bit`** — never shipped. Missed `HMAC verify`, `Grafana Cloud`, `Function URL`.

---

## 2. What Module 11 ships

### 2.1 `README.md` — new structure (top-to-bottom)

1. **Title + one-liner** — full pipeline in one paragraph, `$0/mo` claim upfront.
2. **Badges** — CI, Security, **Tests: 155 passing** (new), Python, Terraform, Free tier, License.
3. **Status line** — `Modules 0-10 complete · 155 / 155 tests passing · terraform validate green · $0/mo projected cost`.
4. **🎬 Watch it work in 90 seconds** — Loom placeholder + three-command demo.
5. **What it does** — 7-step pipeline (detect → enrich → persist → notify → acknowledge → aggregate → visualize).
6. **🎯 Four design decisions worth calling out** — K3s vs EKS, Groq vs Bedrock, Node IAM vs IRSA, aggregator Lambda vs Prometheus. Each links to its ADR / module runbook.
7. **Architecture** — ASCII diagram in-line + link to `docs/diagrams/architecture.mmd` (Mermaid source) + regenerate-PNG command.
8. **Quickstart** — three paths: local kind ($0), real AWS (full story), just watch the demo.
9. **Documentation map** — one row per question, one doc per answer.
10. **Repo layout** — updated tree, top-level `apps/ controller/ lambdas/ helm/ infra/ dashboards/ scripts/ docs/`.
11. **Cost** — bullet per service with free-tier headroom + link to the Module 9 audit table.
12. **Skills exercised** — updated list; removed `Fluent Bit`, added `HMAC`, `Grafana Cloud`, `Function URL`.
13. **License** — MIT.

### 2.2 `docs/diagrams/architecture.mmd` — editable Mermaid source

Left in the repo as the **source of truth**. A colored PNG (`docs/img/architecture.png`) is generated from it via `npx @mermaid-js/mermaid-cli` OR by pasting into [mermaid.live](https://mermaid.live/). The `.mmd` is what code review sees; the `.png` is what the README embeds.

Classes used (all in the file):

| Class     | What it labels           |
|-----------|--------------------------|
| `pod`     | K8s workloads (blue)     |
| `lambda`  | AWS Lambda functions (amber) |
| `bus`     | EventBridge (purple)     |
| `store`   | Persistence — DDB, CW (green) |
| `secret`  | SSM + KMS (red)          |
| `ext`     | External services — Groq, Slack, Grafana (grey) |
| `fnurl`   | Lambda Function URL (dashed amber) |
| `ci`      | GitHub Actions (indigo)  |
| `actor`   | Human/dev (yellow)       |

### 2.3 `docs/11-loom-script.md` — recording script

Three parts:

1. **Take checklist** — commands to run BEFORE hitting Record; window setup order; mic test.
2. **Narration table** — 13 rows, one per beat, each with: timestamp, which window to be sharing, and the exact words to say.
3. **Cue sheet** — per-window "state before recording" (terminal size + ANSI, Slack channel scroll, Grafana time range, DDB console fallback).
4. **Failure modes + recovery** — Slack card doesn't appear, DDB empty, CloudWatch empty, Grafana flat, SSM tunnel closed. Each row says stop-and-retake or live-fix.
5. **Post-production checklist** — trim, thumbnail choice, title, description, README embed step.
6. **Backup** — if you can't spin up a real cluster, `make demo-dry-run` + honesty at 00:00. Recruiters get the story, they don't get the live Restart count. Documented trade-off.

Target runtime: **90 s ± 15 s**. Loom's built-in trim + speed controls handle the polish.

### 2.4 Docs cross-links

- `README.md` → `docs/11-loom-script.md` in the "Live demo" line and the doc map.
- `docs/REFERENCE.md` §11 change-log gets a Module 11 row.
- `PROJECT_CONTEXT.md` "Completed" list gets Module 11; "Left" list drops it; "Immediate next step" points at Module 12.

---

## 3. Design decisions worth calling out

### 3.1 ASCII diagram in the README, Mermaid source in `docs/diagrams/`

Why ASCII in the README?

- **Renders identically everywhere** — GitHub, CLI `less README.md`, VS Code preview, IDE hover, `cat`.
- **Text-searchable** — recruiters using GitHub's code search can find `EventBridge` inside the diagram.
- **Diff-friendly** — a one-line change to the ASCII is a one-line PR diff.

Why Mermaid too?

- Color + shape carry information ASCII can't (secrets are red, Lambdas are amber, event bus is purple).
- A rendered PNG is nicer for the LinkedIn preview when you paste the repo URL.
- `.mmd` files diff cleanly in code review; `.png` files don't.

**Trade-off accepted**: two artifacts to keep in sync. Mitigation: the Mermaid file explicitly points at itself as the source of truth in a top-of-file comment; the README doesn't try to `<img src="architecture.png">` unless the PNG has actually been generated.

### 3.2 Word-for-word script, not "bullet points to riff on"

Recruiters watch the first 30 s. A script optimizes for **information density in 30 s**, and stops me from ad-libbing dead air. Every row of the narration table has a *quantified* claim (`155 tests`, `5 metric series`, `10-metric free-tier ceiling`, `~1 second Groq latency`).

### 3.3 Loom placeholder, not a hard-coded URL

The Loom URL is a manual step *after* the code work, and won't be filled in until the recording is done. Making the README parse before that step lets Module 11 ship without blocking on the recording itself. Anyone rendering the README before the Loom is recorded sees a call-out linking to the script — same information, one more click.

### 3.4 Design-decision block goes ABOVE architecture

Recruiter attention flows top-down. Old README hit architecture first, then buried "why" in ADRs. New order:

```
title → status → hero(Loom) → what it does → WHY (4 decisions) → HOW (architecture) → HOW-TO (quickstart)
```

Each of the four "why" bullets links to a full ADR / runbook, so the depth is there — just below a summary that fits above the fold.

---

## 4. Verification

- **README markdown renders on GitHub** — validated by re-reading with the same Markdown flavor the site uses (GFM). No unclosed lists, no orphan headings, table cells align, code blocks all closed.
- **Every doc link resolves** — `docs/INSTALL.md`, `docs/REFERENCE.md`, `docs/11-loom-script.md`, `docs/06-cost-tracker.md#free-tier-compliance-audit-as-of-module-9`, `docs/adr/001-k3s-vs-eks.md`, `docs/adr/002-ai-backend-choice.md`, `docs/modules/04-controller.md`, `docs/modules/09-observability.md`, `docs/diagrams/architecture.mmd`, `PROJECT_CONTEXT.md`, `LICENSE`.
- **Skills list is truthful** — every item appears in either the code (`hmac.compare_digest` in `remediator/verify.py`, Grafana Cloud in `dashboards/grafana/README.md`, Function URL in `infra/envs/dev/main.tf`) or the docs.

---

## 5. What's still manual (a.k.a. don't-block-the-ship)

- **Actual Loom recording** — script is done; hitting Record is an out-of-repo action.
- **`docs/img/architecture.png`** — Mermaid source is committed; PNG generation is one `npx` command, run by whoever cares about the LinkedIn preview.
- **`docs/img/loom-thumb.png`** — extract from the Loom after recording, save, commit.
- **Real GitHub repo URL** — the badges point at `dhanym/smartops-lite`; if you fork with a different name, replace the org/repo string throughout.

None of these block the code or the "does it work" story.

---

## 6. Change-log

| Date | Change |
|------|--------|
| 2026-08-26 | Initial ship: README rewrite (7 → 13 sections), architecture.mmd Mermaid source, 11-loom-script.md (narration + cue sheet + failure recovery), 11-readme-loom.md runbook. Status bumped to "Modules 0-11 complete". |
