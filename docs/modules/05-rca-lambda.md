# Module 5 — RCA pipeline: EventBridge rule → Lambda → DynamoDB → Slack

> **Build-time runbook.** Written while this module was built, before the first real AWS run. For the tested steps, use [`docs/INSTALL.md`](../INSTALL.md); where the two differ, INSTALL wins.

> The other half of the incident loop. Module 4 turned pod failures into structured events; Module 5 catches those events, persists them, and pings a human. Module 6 will drop LLM-generated RCA text on top of this exact shape.

## What ships in this module (5.0)

| Artifact | Purpose |
|---|---|
| `infra/modules/dynamodb/` | Reusable Terraform module — on-demand DDB table (SSE on, PITR/TTL opt-in) |
| `infra/modules/lambda/` | Reusable Terraform module — source-archive + IAM role + log group + function |
| `lambdas/rca-generator/` (Python) | The Lambda code: parses events, writes DDB, pings Slack |
| Wiring in `infra/envs/dev/main.tf` | EventBridge rule + target + `aws_lambda_permission` |
| Makefile targets | `logs-rca`, `invoke-rca-sample`, `ddb-scan-incidents` |
| Extended `scripts/verify.sh` | Checks Lambda state=Active + DDB table ACTIVE + rule → target wiring + recent invocations |

**Deferred to Module 5.1:** Fluent Bit DaemonSet → CloudWatch Logs (enriches the Lambda with recent log lines from the failing pod).
**Deferred to Module 6:** Groq LLM RCA text + Slack Block Kit formatting.

## Architecture

```
smartops-controller (Module 4, running in K3s)
        │
        │ boto3 PutEvents  (source=smartops.controller, DetailType=IncidentDetected)
        ▼
┌─────────────────────────────────────────────────────────┐
│  EventBridge custom bus: smartops-dev                    │
│                                                          │
│  ┌────────────────────────────────────────────────┐      │
│  │  rule: smartops-lite-incident-detected         │      │
│  │  event_pattern:                                │      │
│  │    source = smartops.controller                │      │
│  │    detail-type = IncidentDetected              │      │
│  └────────────────────┬───────────────────────────┘      │
└────────────────────────┼─────────────────────────────────┘
                         │  (aws_lambda_permission grants
                         │   events.amazonaws.com → InvokeFunction)
                         ▼
┌─────────────────────────────────────────────────────────┐
│  Lambda: smartops-lite-rca-generator                     │
│                                                          │
│   cold start (once per container):                       │
│     Config.from_env()                                    │
│     Secrets.load()  ── SSM GetParameters ──►  SSM        │
│                                                          │
│   per-invocation:                                        │
│     parse_event()          ── schema v1.0 validate       │
│     persist()              ── DDB put_item ───►  DDB     │
│     notify()               ── HTTPS POST ─────►  Slack   │
└──────────────────────────────────────────────────────────┘
                         │                     │
                         ▼                     ▼
                 DynamoDB                Slack webhook
                 smartops-incidents      (fail-soft)
                 (put_item, idempotent)
```

## Why this shape

### One Lambda per rule (not a shared "router")

We could have built one big Lambda that receives EVERY event on the bus and dispatches by `detail-type`. Simpler routing, more code. We chose per-rule Lambdas instead because:
- **Blast radius:** a bug in the RCA Lambda can't crash a future remediator Lambda if they're separate.
- **IAM tightness:** each function's execution role gets ONLY the permissions its narrow purpose needs.
- **Cost invariance:** on-demand Lambda cost is the same whether one function or ten handle 1000 events.

### boto3 low-level client instead of Table resource

`dynamodb.Table("smartops-incidents").put_item(...)` is prettier but pulls in `boto3.dynamodb.types.TypeSerializer` which needs the `decimal` module and is slower at cold-start. We do the marshalling manually in `persistence._to_attr_value()` — 20 lines of code that handles every type this Lambda actually produces.

### `urllib.request` instead of `requests`

`requests` would add ~300 KB to the deployment package and slow cold-start. `urllib.request` from stdlib is enough for a single JSON POST. Fail-soft error handling means a bad webhook can't take down the pipeline.

### Fail-loud on schema, fail-soft on Slack

- **Schema errors raise** → EventBridge retries the invocation for 24h → we don't silently drop malformed events (which are more likely bugs than user errors).
- **Slack errors log** → DDB writes still succeed → a Slack outage never blocks incident persistence.

### Cold-start-only secret fetch

`SSM GetParameters` costs ~$0.05 per 10K calls. Doing it once per container (not once per invocation) keeps us free-tier even at 100K events/mo. The trade-off: rotating a Slack webhook requires waiting for containers to recycle (~15 min under normal traffic).

## Event schema consumption

Full contract lives in [Module 4](./04-controller.md). Highlights:

- Every event has `detail.schemaVersion = "1.0"`.
- Required fields: `incidentId`, `namespace`, `podName`, `containerName`, `reason`, `timestamp`.
- Optional fields default to sensible values: `zone=None`, `exitCode=None`, `labels={}`.
- `SUPPORTED_SCHEMA_VERSIONS` in `schema.py` guards against silent-drift bugs.

**When the schema changes in a future controller version:**
1. Bump `schemaVersion` in the controller (e.g. `"1.1"`).
2. Add `"1.1"` to `SUPPORTED_SCHEMA_VERSIONS` here.
3. If field shapes changed, add a translator branch in `parse_event()`.
4. Deploy Lambda BEFORE controller — this way old events keep working during the rollout.

## DynamoDB schema

Table: **`smartops-incidents`** (configurable via `var.incidents_table_name`).

- Billing: `PAY_PER_REQUEST` — no capacity planning, ~$0 at our volume.
- Hash key: `incidentId` (S) — 1:1 with the controller's UUID.
- Attributes written by the Lambda:

| Attribute | Type | Source |
|---|---|---|
| `incidentId`     | S | from event |
| `schemaVersion`  | S | from event |
| `namespace`      | S | from event |
| `podName`        | S | from event |
| `podUid`         | S | from event |
| `containerName`  | S | from event |
| `reason`         | S | from event |
| `restartCount`   | N | from event |
| `nodeName`       | S | from event |
| `zone`           | S \| NULL | from event |
| `timestamp`      | S | from event (RFC3339 UTC) |
| `message`        | S | from event |
| `exitCode`       | N \| NULL | from event |
| `labels`         | M<S,S> | from event |
| `ingestedAt`     | S | Lambda-generated (persist-time RFC3339) |
| `rcaText`        | S | placeholder in 5.0, overwritten in Module 6 |
| `rcaStatus`      | S | "pending" (5.0) → "generated" (Module 6) |

**Why no GSIs today.** Everything we currently query is by `incidentId`. Add one later if we grow a `list incidents by namespace/reason` UI.

## Slack format (5.0 — plain text)

```
:rotating_light: *SmartOps incident* — `CrashLoopBackOff`
pod `demo/app-crashy-app-6b8c-xyz` container `crashy`
restarts=5 node=`ip-10-0-1-42`
zone=`ap-south-1a`
_incident id: `b48b9a2d-e46c-4c1a-9f26-1d2d78d15f39`_
```

Module 6 will replace this with a Block Kit message that includes the LLM-generated RCA + severity badge + interactive buttons.

## Environment variables (set by Terraform)

Non-secret operational config. Secrets are always in SSM SecureString.

| Var | Set to |
|---|---|
| `INCIDENTS_TABLE_NAME`     | `smartops-incidents` |
| `SSM_SLACK_WEBHOOK_PATH`   | `/smartops/dev/slack_webhook` |
| `SSM_GROQ_KEY_PATH`        | `/smartops/dev/groq_api_key` (unused in 5.0, ready for Module 6) |
| `SLACK_ENABLED`            | `"true"` / `"false"` global kill-switch |
| `LOG_LEVEL`                | `INFO` |
| `SCHEMA_VERSION_EXPECTED`  | `1.0` |
| `AWS_REGION`               | injected by Lambda runtime |

## IAM policy — least-privilege breakdown

The execution role has only what the Lambda actually calls:

| Statement | Actions | Resources |
|---|---|---|
| Managed: `AWSLambdaBasicExecutionRole` | logs:CreateLogStream, logs:PutLogEvents | Own log group |
| Inline `PersistIncidentsToDynamo` | dynamodb:{PutItem, UpdateItem, GetItem} | `arn:aws:dynamodb:...:table/smartops-incidents` (ONE ARN) |
| Inline `ReadSecretsFromSSM` | ssm:{GetParameter, GetParameters} | `.../parameter/smartops/dev/slack_webhook` + `.../parameter/smartops/dev/groq_api_key` (TWO ARNs) |
| Inline `DecryptSSMSecureString` | kms:Decrypt | `*` (constrained by `Condition: kms:ViaService = ssm.<region>.amazonaws.com`) |

No wildcards on actions. No `s3:*` or `iam:*` anywhere. `terraform plan -out=x && terraform show -json x | jq '.iam'` — audit-ready.

## Local demo (no AWS)

The Lambda's unit tests run entirely offline. `moto` mocks DDB + SSM; a monkey-patched `urllib.request.urlopen` simulates Slack.

```bash
cd lambdas/rca-generator
poetry install --with dev
poetry run pytest -v
# → 25+ tests, ~1 second
```

## Real-AWS demo

```bash
# 1) Deploy everything (Module 1-5 all in one apply)
make tf-apply

# 2) Confirm the pipeline is wired
make verify --module 5      # (or: make verify)

# 3) Fire a synthetic event WITHOUT triggering a real pod failure
make invoke-rca-sample

# 4) Watch the Lambda logs (Ctrl-C to stop)
make logs-rca

# 5) Inspect what landed in DDB
make ddb-scan-incidents

# 6) Trigger a REAL incident end-to-end (crashy-app → controller → EventBridge → Lambda)
make chaos-crash
make logs-rca               # should show handler start / handler done
make ddb-scan-incidents     # should show 1 new row with rcaStatus=pending
```

## Testing

`lambdas/rca-generator/tests/`:

- `test_schema.py` — 11 tests covering the parser: happy path, wrong source, wrong detail-type, missing detail, unsupported schemaVersion, every required field missing, optional-field defaults, exitCode coercion, restartCount type errors, labels type errors.
- `test_persistence.py` — 5 tests covering the DDB writer: type marshalling table, lambda-added fields, round-trip write+read, idempotent same-key write, NULL handling for optional fields.
- `test_notifier.py` — 5 tests covering Slack: message shape, missing-webhook short-circuit, JSON body shape, fail-soft on URLError, fail-soft on non-2xx.
- `test_handler.py` — 6 end-to-end tests: full happy path (event → DDB row + Slack ping), Slack-disabled path, Slack-failure fails-soft path, schema-error raises + no partial DDB write, config env-var loading, config missing-var error.

## Cost

At demo scale:
- **Lambda:** ~5 invocations/hr during a demo = 120/day → free tier easily.
- **DynamoDB (on-demand):** 120 writes/day, ~1 KB each → free tier.
- **CloudWatch Logs:** ~1 MB/day, 14-day retention → free tier.
- **EventBridge:** custom bus is free (only cross-account has cost). Rule invocations are free.
- **SSM GetParameters:** 1 call per Lambda cold-start (~10/day) → free tier.

Total marginal cost of Module 5 on top of Module 4: **$0/mo** at demo volumes.

## Known limitations (deferred to later modules)

1. **No log enrichment.** The event doesn't include the pod's stdout/stderr. Module 5.1 adds Fluent Bit → CloudWatch Logs → Lambda queries recent log lines.
2. **Placeholder RCA text.** `rcaText` is a literal string in 5.0. Module 6 replaces it with a Groq LLM call.
3. **Plain-text Slack.** Module 6 upgrades to Block Kit with severity color, RCA excerpt, and an "acknowledge" button.
4. **No DLQ.** EventBridge retries for 24h; unrecoverable events are dropped after that. Module 7 adds a proper SQS DLQ + on-failure destination for offline audit.
5. **No cross-account.** Only one AWS account. When we split env → prod → sandbox, the bus + rule pattern will need account-boundary hardening.

Full CLI reference lives in [`docs/REFERENCE.md`](../REFERENCE.md).
