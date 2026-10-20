# remediator — Slack interaction receiver

Module 7.0 Lambda. Receives Slack Block Kit `block_actions` payloads via a
Lambda **Function URL** (no API Gateway needed — cheaper + simpler for a
single-endpoint webhook), verifies the HMAC signature, and:

1. Updates the incident row in DynamoDB: `rcaStatus="acknowledged"`,
   `acknowledgedBy=<slack_user_id>`, `acknowledgedAt=<iso>`.
2. Replaces the "Acknowledge" button in the original Slack message with a
   context row showing who acknowledged and when.
3. For a **whitelisted set of reasons** (configurable, empty by default),
   emits a `RemediationRequested` event onto the SmartOps bus for a future
   subscriber (Module 7.1) to consume.

## Environment variables

| Var | Default | Meaning |
|---|---|---|
| `INCIDENTS_TABLE_NAME`         | (required) | DDB table populated by rca-generator |
| `SSM_SLACK_SIGNING_SECRET_PATH`| (required) | SSM SecureString holding Slack app signing secret |
| `EVENT_BUS_NAME`               | (required) | SmartOps EventBridge bus (same one the controller uses) |
| `ALLOWED_REMEDIATION_REASONS`  | `""`       | Comma-separated list of reasons that emit RemediationRequested. Empty = ack-only mode. |
| `REPLAY_WINDOW_SECONDS`        | `300`      | Reject Slack messages older than this (replay attack mitigation) |
| `LOG_LEVEL`                    | `INFO`     | Structured JSON log level |
| `AWS_REGION`                   | `ap-south-1` | For boto3 clients |

## Fail policy

| Step | Failure mode | Behavior |
|---|---|---|
| **1. Signature verify**   | Bad HMAC, missing headers, stale timestamp | **401** — Slack retries automatically |
| **2. Body parse**         | Malformed payload, missing action        | **400** — bug in the caller, do not retry |
| **3. DDB update**         | Throttle / IAM / not-found               | **500** — Slack shows generic error |
| **4. Bus publish**        | EventBridge failure                       | **Soft** — ack succeeded, log warning |
| **5. Response render**    | (never fails — pure)                      | — |

## Local tests

```bash
cd lambdas/remediator
poetry install --with dev
poetry run pytest -v
```

All tests hermetic — moto mocks DDB + EventBridge, HMAC + urllib stubbed.
