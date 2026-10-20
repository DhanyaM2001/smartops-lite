# rca-generator Lambda

Consumes `IncidentDetected` events from the SmartOps EventBridge bus and:

1. Parses the payload against the v1.0 schema from Module 4.
2. Writes a row to DynamoDB `smartops-incidents` (idempotent by `incidentId`).
3. Posts a plain-text ping to the Slack webhook stored in SSM.

Module 6 will layer Groq LLM RCA text + Block Kit formatting on top.

## Wire diagram

```
smartops-controller (Module 4)
        │
        │ PutEvents (source=smartops.controller, detail-type=IncidentDetected)
        ▼
EventBridge bus: smartops-dev
        │
        │ rule: smartops-lite-incident-detected
        ▼
Lambda: smartops-lite-rca-generator
        │
        ├──► DynamoDB smartops-incidents  (put_item, idempotent)
        │
        └──► Slack webhook                (fail-soft, never blocks DDB)
```

## Environment variables (set by Terraform)

| Var | Meaning |
|---|---|
| `INCIDENTS_TABLE_NAME`     | DDB table to write to |
| `SSM_SLACK_WEBHOOK_PATH`   | SSM path holding the Slack webhook URL |
| `SSM_GROQ_KEY_PATH`        | SSM path for Groq (unused today, ready for Module 6) |
| `SLACK_ENABLED`            | "true"/"false" — global kill-switch for Slack pings |
| `LOG_LEVEL`                | INFO/DEBUG/WARNING |
| `SCHEMA_VERSION_EXPECTED`  | Fails schema check if event doesn't match |
| `AWS_REGION`               | Injected by Lambda runtime; used for boto3 clients |

Secrets are **never** in env vars — they come from SSM SecureString at cold start.

## Local testing

```bash
cd lambdas/rca-generator
poetry install --with dev
poetry run pytest -v
```

All tests are hermetic: `moto` mocks DDB + SSM, `urllib.request` is monkey-patched
for Slack. No AWS credentials needed.

## Deployment

The Lambda ships zipped by `infra/modules/lambda/` and applied via `make tf-apply`.
On every `terraform plan`:
- `data "archive_file"` re-zips `src/` (excludes tests, __pycache__, etc.)
- The `source_code_hash` output changes only when the zip contents change,
  so hotless code changes trigger a Lambda update automatically.

## Files

```
src/rca_generator/
├─ __init__.py     — version marker
├─ config.py       — env-var loader + SSM secret fetcher
├─ schema.py       — Incident dataclass + parse_event() validator
├─ persistence.py  — DDB writer (build_item + persist + marshaller)
├─ notifier.py     — Slack webhook client (stdlib urllib, fail-soft)
└─ handler.py      — Lambda entry point (wires everything)

tests/
├─ conftest.py         — moto fixtures + reusable event/incident builders
├─ test_schema.py      — parse_event happy + error paths
├─ test_persistence.py — DDB marshall + put_item round-trip
├─ test_notifier.py    — Slack HTTP layer with urllib patched
└─ test_handler.py     — end-to-end handler with moto DDB + SSM
```
