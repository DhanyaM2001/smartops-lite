# Module 6 — Groq LLM RCA + Block Kit Slack

> **Build-time runbook.** Written while this module was built, before the first real AWS run. For the tested steps, use [`docs/INSTALL.md`](../INSTALL.md); where the two differ, INSTALL wins. The default model here was `llama-3.3-70b-versatile`; Groq retired it during the first AWS run and the default is now `qwen/qwen3.8-27b` (Terraform variable `llm_model`).

> **The "AI-native" moment.** Same pipeline as Module 5.0, but between "parse" and "persist" the Lambda now asks Groq to write two sentences of root-cause analysis, and the Slack ping arrives as a rich Block Kit card with severity color, RCA text, and an "Acknowledge" button.

## What ships in this module

| Artifact | Purpose |
|---|---|
| `lambdas/rca-generator/src/rca_generator/rca_llm.py`      | Groq API client (stdlib `urllib`, fail-soft, cost-safe) |
| `lambdas/rca-generator/src/rca_generator/slack_blocks.py` | Block Kit payload builder — severity color + RCA + Acknowledge button |
| Modified `notifier.py`     | New `send_payload(dict)` — dispatches any JSON body (Block Kit or plain) |
| Modified `config.py`       | New env vars: `LLM_ENABLED`, `LLM_MODEL`, `LLM_TIMEOUT_SECONDS`, `LLM_MAX_TOKENS`, `SLACK_BLOCKS_ENABLED` |
| Modified `persistence.py`  | Accepts `rca_text` / `rca_status` / `rca_source`; DDB rows flip `pending → generated` when LLM succeeds |
| Modified `handler.py`      | Adds LLM step between parse and persist; Block Kit dispatch |
| Modified `infra/envs/dev/*.tf` | New TF vars (`llm_enabled`, `llm_model`, `llm_timeout_seconds`, `llm_max_tokens`, `slack_blocks_enabled`, `rca_lambda_timeout_seconds`) + wired into Lambda env vars; Lambda timeout bumped 30s → 60s |

**No new AWS services touched.** No IAM changes (Groq API key was already loaded from SSM in Module 5.0's cold-start `Secrets.load()`). No new Terraform modules. This module is a pure code-layer upgrade to the RCA Lambda.

## Architecture

```
smartops-controller
        │
        │ IncidentDetected
        ▼
EventBridge rule → Lambda: smartops-lite-rca-generator
        │
        ├─ 1) parse_event()         ── schema v1.0 validate
        │
        ├─ 2) rca_llm.generate_rca()   ── POST api.groq.com/openai/v1/chat/completions
        │        │                       (~1s typical, 10s timeout, fail-soft)
        │        ▼
        │   Groq (qwen/qwen3.8-27b by default)
        │
        ├─ 3) persist()             ── put_item to DynamoDB
        │        (rcaText = LLM output, rcaStatus = "generated"/"pending",
        │         rcaSource = "groq"/"fallback"/"none")
        │
        └─ 4) send_payload()        ── POST Slack webhook
                 (Block Kit if SLACK_BLOCKS_ENABLED=true, plain-text otherwise)
```

## Fail policy — unchanged from Module 5.0 + one new tier

| Step        | Failure mode | What happens |
|---|---|---|
| **1. parse**   | Schema mismatch, missing detail    | **RAISE** — EventBridge retries the invocation for 24h |
| **2. LLM**     | Timeout, HTTP 5xx, malformed body  | **SOFT** — `rca_text = None`, `rcaSource = "fallback"`, continue |
| **3. persist** | DDB throttling / permission        | **RAISE** — EventBridge retries; incident MUST land |
| **4. Slack**   | Webhook 5xx, invalid URL, timeout  | **SOFT** — DDB row is already written; notification lost |

The point: **an LLM outage cannot lose incidents, and a Slack outage cannot lose incidents.** Only a parse or DDB failure raises — and both are retried by EventBridge automatically.

## Prompt design

System prompt (fixed):

> You are a senior Site Reliability Engineer analyzing a Kubernetes pod failure. You must respond in TWO sentences maximum:
>   1. A one-sentence root-cause hypothesis based on the observable signal.
>   2. A one-sentence recommended next action (kubectl command, code check, or config to inspect).
>
> Be specific to the reason. Never speculate beyond the evidence. Never include headings, bullets, code fences, or apologies. Plain text only.

User prompt (data-driven, built by `build_user_prompt(incident)`):

```
Kubernetes pod-failure incident:
  reason:         CrashLoopBackOff
  namespace:      demo
  pod:            app-crashy-app-6b8c-xyz
  container:      crashy
  restart_count:  5
  exit_code:      n/a
  node:           ip-10-0-1-42
  zone:           ap-south-1a
  timestamp:      2026-08-24T10:15:32Z
  kubelet msg:    Back-off 5m0s restarting failed container
  labels:         {"app.kubernetes.io/name": "crashy-app"}

Analyze and respond in two sentences (cause + next action).
```

**Why so structured.** LLMs perform noticeably better on tabular data than paragraph prompts. Every field maps 1:1 to the Module 4 `Incident` schema — swap the model, keep the shape.

**Why labels are filtered.** Only `app.kubernetes.io/name` and `app.kubernetes.io/component` are surfaced. Pods often carry 20+ operator-owned labels that would blow past the token budget without helping the model.

## Slack Block Kit card — anatomy

```
┌────────────────────────────────────────────────────────────────┐
│ 🚨 CrashLoopBackOff — demo/app-crashy-app-6b8c-xyz              │  ← header
├────────────────────────────────────────────────────────────────┤
│ container `crashy` · restarts `5` · node `ip-10-0-1-42` ·      │  ← context row
│   zone `ap-south-1a`                                           │
├────────────────────────────────────────────────────────────────┤
│ Message                                                        │  ← section (kubelet)
│ ```Back-off 5m0s restarting failed container```                │
├────────────────────────────────────────────────────────────────┤
│ RCA                                                            │  ← section (LLM)
│ The crashy container keeps exiting non-zero, indicating an     │
│ application panic on startup. Check                            │
│ `kubectl logs demo/app-crashy-app-6b8c-xyz -c crashy --previous`│
├────────────────────────────────────────────────────────────────┤
│ [ Acknowledge ]                                                │  ← actions
├────────────────────────────────────────────────────────────────┤
│ incident b48b9a2d… · schema v1.0 · 2026-08-24T10:15:32Z         │  ← footer
└────────────────────────────────────────────────────────────────┘
   ← red vertical stripe (color = #d0021b for CrashLoopBackOff)
```

**Severity → color map** (in `slack_blocks._SEVERITY_COLOR`):

| Reason | Color |
|---|---|
| `CrashLoopBackOff`, `Error`, `PodFailed`               | `#d0021b` (red) |
| `OOMKilled`, `CreateContainerConfigError`, `RunContainerError`, `CreateContainerError` | `#f5a623` (orange) |
| `ImagePullBackOff`, `ErrImagePull`, `ErrImageNeverPull` | `#f8e71c` (yellow) |
| unknown | `#9b9b9b` (grey) |

**Acknowledge button.** Carries `action_id: smartops_acknowledge` and `value: {incidentId}`. Module 7 wires a subscriber that receives this click and marks `rcaStatus: acknowledged` on the DDB row + kicks off remediation.

## New environment variables (all set by Terraform)

| Var | Default | Meaning |
|---|---|---|
| `LLM_ENABLED`          | `true`  | Master kill-switch for the Groq call. `false` → skip, fall through to placeholder. |
| `LLM_MODEL`            | `qwen/qwen3.8-27b` | Any Groq-supported model id. Swap without redeploying code. |
| `LLM_TIMEOUT_SECONDS`  | `10`    | Per-invocation HTTP timeout on the Groq call. Must be < `rca_lambda_timeout_seconds`. |
| `LLM_MAX_TOKENS`       | `200`   | Response cap. 200 fits comfortably in 2 sentences. |
| `SLACK_BLOCKS_ENABLED` | `true`  | Send Block Kit if true, plain text if false (Module 5.0 fallback). |

## New Terraform variables

Same names, exposed at the env-root level so you can toggle without touching code:

```hcl
llm_enabled                = true
llm_model                  = "qwen/qwen3.8-27b"
llm_timeout_seconds        = 10
llm_max_tokens             = 200
slack_blocks_enabled       = true
rca_lambda_timeout_seconds = 60  # bumped from 30s in Module 5.0
```

## DDB row changes

Module 5.0 shape is preserved. Module 6 adds one new attribute (`rcaSource`) and flips the semantics of two existing ones:

| Attribute   | 5.0 value                              | 6 value                                       |
|---|---|---|
| `rcaText`   | Literal placeholder string             | LLM output (up to `LLM_MAX_TOKENS`)           |
| `rcaStatus` | `"pending"` (always)                   | `"generated"` on LLM success, `"pending"` on LLM failure or disabled |
| `rcaSource` | (didn't exist)                         | `"groq"` / `"fallback"` / `"none"`             |

**No DDB migration required.** Existing Module 5.0 rows still parse (`rcaSource` is just missing). The Module 5.0 `persist()` signature is preserved for backward compat (all new args are keyword-only with sane defaults).

## Cost

Additional cost on top of Module 5.0:

- **Groq API**: free tier is 30 requests/min. At demo scale (~5 incidents/hr) we're 0.1% of quota. Zero dollars.
- **Lambda duration**: cold start unchanged; warm invocations grow from ~200ms → ~1500ms (Groq call). Free tier covers 400k GB-seconds/mo — we'd need ~11k invocations/day to hit it.
- **Slack**: unlimited free webhooks.

Total marginal cost of Module 6 on top of Module 5.0: **$0/mo** at demo volumes.

## Local demo (no AWS, no Groq needed)

All 32 tests are hermetic — moto mocks DDB + SSM, `urllib.request.urlopen` is monkey-patched for both Slack and Groq.

```bash
cd lambdas/rca-generator
poetry install --with dev
poetry run pytest -v
# → 32 tests, ~1 second
```

## Real-AWS demo

Prereq: Groq API key stored in SSM at `/smartops/dev/groq_api_key` (Module 0's `make put-secrets` handles this).

```bash
# 1) Redeploy the Lambda (source hash changes → TF replaces the function code)
make tf-apply

# 2) Verify Module 6 wiring
make verify --module 5   # (same gate; Lambda is still smartops-lite-rca-generator)

# 3) Fire a synthetic incident and watch the AI-generated card arrive in Slack
make invoke-rca-sample
make logs-rca          # in another terminal — you'll see "groq rca generated"

# 4) Inspect the DDB row (rcaText now has real LLM output)
make ddb-scan-incidents

# 5) Trigger a real incident end-to-end
make chaos-crash
# Watch Slack — Block Kit card lands within ~5s with severity color + RCA
```

## Model swap without redeploy

Groq's roster changes quarterly, and a retired model returns HTTP 404
`model_not_found` (the Lambda then falls back with `rcaSource="fallback"`).
List the models your key can use with `GET https://api.groq.com/openai/v1/models`,
and pick one whose answer ends with `finish_reason: "stop"` inside
`LLM_MAX_TOKENS` — reasoning models spend part of that cap thinking. To switch:

```bash
# 1) Set the TF variable — no code change needed
echo 'llm_model = "openai/gpt-oss-120b"' >> infra/envs/dev/terraform.tfvars

# 2) Re-apply — only the Lambda env var changes, no code redeploy
make tf-apply

# 3) Next invocation uses the new model
```

## Known limitations (deferred)

1. **Ack button is decorative.** Clicking it hits Slack's default handler and does nothing. Module 7 adds an API Gateway → Lambda subscriber that receives the interaction payload, flips `rcaStatus: acknowledged`, and (optionally) triggers restart.
2. **No RCA re-generation.** Once written, `rcaText` is final. If the LLM output is poor, humans currently have to Groq-it manually. A "Regenerate" button + `rca_llm.generate_rca()` re-invocation is a nice-to-have.
3. **English only.** Prompt is hardcoded English. Localization = new prompt template per language + `LLM_LANGUAGE` env var. Not planned before v1.0.
4. **No log context.** The LLM sees metadata only. Module 5.1 (Fluent Bit) would add recent stdout/stderr — deferred as low-portfolio-value overhead.
5. **No streaming.** We wait for the full response. Streaming would cut perceived latency but Slack webhooks don't support it anyway.

Full CLI reference lives in [`docs/REFERENCE.md`](../REFERENCE.md).
