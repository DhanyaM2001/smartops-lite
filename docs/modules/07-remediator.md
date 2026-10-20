# Module 7.0 — Remediator: Slack Ack button receiver

> **Build-time runbook.** Written while this module was built, before the first real AWS run. For the tested steps, use [`docs/INSTALL.md`](../INSTALL.md); where the two differ, INSTALL wins. The remediator is deployed by `make tf-apply`, but the Slack side (signing secret + Interactivity URL) wasn't set up in the recorded run; the steps to do it are below.

> **The closing of the loop.** Module 6 posted a Slack card with an "Acknowledge" button that carried the `incidentId`. Module 7.0 wires the *other end* — a public HTTPS endpoint that receives Slack's `block_actions` payload when a human clicks it, verifies the signature, writes the ack to DynamoDB, and replaces the button with an "✔ Acknowledged by @user" footer.

## Scope split — why 7.0 vs 7.1

The `RemediationRequested` event that Module 7.0 emits is intentionally **without a receiver**. The actual `kubectl patch` executor (bumping memory limits on `OOMKilled`, deleting misbehaving pods, etc.) lands in **Module 7.1** and needs a design call:

| Option | Cost | Complexity | Notes |
|---|---|---|---|
| Lambda-in-VPC + VPC endpoints | ~$7/mo per endpoint (SSM, DDB, EventBridge) | Medium | The "textbook AWS" answer. Adds NAT-adjacent cost. |
| Controller subscribes via SQS | $0/mo | Higher — new SQS module + controller subscriber goroutine | Reuses the K3s pod's existing kube-API-client. Cleaner blast radius. |
| Skip actual patching entirely | $0 | Low | 7.0 only. Ack + record is still portfolio-valuable. |

Deferring lets us ship Module 7.0's Slack UX today without paying the design cost.

## What ships in this module

| Artifact | Purpose |
|---|---|
| `lambdas/remediator/src/remediator/config.py`       | `Config` + `Secrets` (mirrors `rca_generator` pattern). New env vars: `INCIDENTS_TABLE_NAME`, `SSM_SLACK_SIGNING_SECRET_PATH`, `EVENT_BUS_NAME`, `ALLOWED_REMEDIATION_REASONS`, `REPLAY_WINDOW_SECONDS`. |
| `lambdas/remediator/src/remediator/verify.py`       | Slack HMAC-SHA256 verification per Slack docs. Constant-time compare. Timestamp replay-window guard. Every failure path raises `VerificationError` (returned as 401). |
| `lambdas/remediator/src/remediator/persistence.py`  | Conditional `UpdateItem` — flips `rcaStatus: generated → acknowledged`, writes `acknowledgedBy` + `acknowledgedAt`. Double-clicks raise `AlreadyAcknowledged` carrying the *prior* actor. |
| `lambdas/remediator/src/remediator/slack.py`        | Response payload builder — rebuilds the original message with the actions block stripped and an ack-footer context row appended. `build_already_ack_response()` for double-clicks. `build_error_response()` for 5xx. |
| `lambdas/remediator/src/remediator/bus.py`          | `PutEvents` a `RemediationRequested` event onto the SmartOps bus. Fail-soft: bus failure never rolls back the ack. |
| `lambdas/remediator/src/remediator/handler.py`      | Lambda Function URL entry point. Cold-start init + per-invocation flow: decode → verify → parse → persist → (whitelist? bus) → respond. |
| `infra/envs/dev/main.tf`                            | New `module.lambda_remediator` + `aws_lambda_function_url.remediator` + new SSM local (`ssm_slack_signing_secret_path`) + tight IAM (DDB `UpdateItem/GetItem` on ONE table, `events:PutEvents` on ONE bus, `ssm:GetParameter*` on ONE param, `kms:Decrypt` via SSM only). |
| `infra/envs/dev/variables.tf`                       | New vars: `allowed_remediation_reasons`, `slack_replay_window_seconds`, `remediator_lambda_timeout_seconds`. |
| `infra/envs/dev/outputs.tf`                         | New outputs: `remediator_lambda_name/arn/log_group`, `remediator_function_url`, `ssm_slack_signing_secret_path`. |
| `scripts/put-secrets.sh`                            | New `--only-signing` mode + reads `SLACK_SIGNING_SECRET` env var. |
| `Makefile`                                          | New §2.7 targets: `logs-remediator`, `remediator-url`, `put-signing-secret`, `ddb-scan-acked`. |

**No new AWS services introduced.** No new Terraform modules. Reuses the existing `infra/modules/lambda/` module — proves the reusability pattern from Module 5 was correctly generalized.

## Architecture

```
User clicks "Acknowledge" in Slack card (Module 6)
                 │
                 │ POST + HMAC-signed body
                 ▼
        Lambda Function URL (public HTTPS, no API Gateway)
                 │
                 ▼
    smartops-lite-remediator Lambda
                 │
    1. verify.verify()      ── HMAC-SHA256 + 5-min replay window
    2. urllib.parse_qs()    ── extract `payload=` from form body
    3. json.loads()         ── parse Slack interaction JSON
    4. persistence.acknowledge()  ── DDB UpdateItem (conditional)
                 │
                 ├─ 5a. If reason in ALLOWED_REMEDIATION_REASONS:
                 │       bus.request_remediation()  ── PutEvents (soft-fail)
                 │       Source=smartops.remediator, DetailType=RemediationRequested
                 │       (Module 7.1's executor consumes this)
                 │
                 └─ 5b. slack.build_ack_response()
                          ── replaces button with footer
                          ── returned as immediate 200 body
                 │
                 ▼
User's Slack message updates in-place — button → "✔ Acknowledged by @dev at 10:15 UTC"
```

## Slack HMAC verification — exact algorithm

Per [Slack's docs](https://api.slack.com/authentication/verifying-requests-from-slack):

```python
sig_basestring = f"v0:{X-Slack-Request-Timestamp}:{raw_body}"
expected       = "v0=" + HMAC-SHA256(signing_secret, sig_basestring)
if not hmac.compare_digest(expected, X-Slack-Signature):
    reject(401)
if abs(now - timestamp) > REPLAY_WINDOW_SECONDS:
    reject(401)
```

Constant-time compare prevents timing side-channels. The `raw_body` is the URL-encoded form bytes as-received — **do not** parse before verifying.

## DDB update semantics

The UpdateItem uses a **conditional expression** so we can distinguish three cases:

```
ConditionExpression:
  attribute_exists(incidentId) AND (attribute_not_exists(rcaStatus) OR rcaStatus <> :ack)
```

| Case | ConditionalCheckFailed? | Response |
|---|---|---|
| First ack on an existing row | No — writes succeed | 200 with ack footer |
| Row exists, already acknowledged | Yes — we re-read to fetch `acknowledgedBy/At` | 200 with "already acknowledged by @first-actor" footer |
| Row doesn't exist | Yes — but re-read returns nothing → re-raise | 500 with ephemeral error toast |

**Double-click is a happy path.** Two devs clicking simultaneously = second gets an informative response naming the first, not an error.

## Fail policy

| Step | Failure mode | HTTP | Retry? |
|---|---|---|---|
| **1. Signature verify** | HMAC mismatch, stale ts, missing headers | **401** | Slack retries a few times, then gives up (correct — the failure is auth) |
| **2. Body parse**       | Malformed form-body, missing `actions[0]` | **400** | No (caller bug) |
| **3. Unknown action_id**| Not `smartops_acknowledge`               | **200** empty | — (silently ignored) |
| **4. DDB update**       | Throttle / IAM / row-missing            | **500** with ephemeral error | Slack retries — usually helps for throttling |
| **5. Bus publish**      | EventBridge failure                     | (already 200'd) | Soft — logs warning, ack still lands |
| **6. Response render**  | (never fails)                           | — | — |

**The critical invariant:** if the ack made it to DDB, the user sees a green checkmark in Slack. If the ack did NOT make it to DDB, the user sees an error toast — never a false success.

## Security posture

| Threat | Mitigation |
|---|---|
| **Forged requests** (attacker POSTs to the URL directly) | Slack HMAC signature — attacker doesn't have the signing secret |
| **Replay attacks** (attacker captures a real request and re-sends) | `REPLAY_WINDOW_SECONDS=300` (Slack's own recommendation) |
| **Timing side-channels** on signature comparison | `hmac.compare_digest()` — constant-time |
| **Signing secret leak** | Stored as SSM SecureString + KMS decryption gated by `kms:ViaService=ssm.<region>.amazonaws.com` |
| **DDB tampering** by other Lambdas | IAM policy scopes `UpdateItem` to ONE table ARN |
| **Bus abuse** (Lambda publishing arbitrary events) | IAM policy scopes `events:PutEvents` to ONE bus ARN |
| **Logs leak signing secret** | Structured logger never touches `secrets.slack_signing_secret` — only key existence is logged |

## Setup: one-time real-AWS flow

```bash
# 1. Get your Slack app signing secret
#    Slack App admin → Basic Information → App Credentials → Signing Secret (32 hex chars)

read -rs SLACK_SIGNING_SECRET; export SLACK_SIGNING_SECRET
make put-signing-secret       # writes SSM SecureString

# 2. Deploy Module 7 Lambda + Function URL
make tf-apply

# 3. Get the public URL to paste back into Slack
make remediator-url
# → https://<hash>.lambda-url.ap-south-1.on.aws/

# 4. In Slack app → Interactivity & Shortcuts → toggle ON → paste URL
#    Save → Reinstall app to workspace

# 5. Test: trigger a real incident and click "Acknowledge"
make chaos-crash
# (wait for Slack card — click Acknowledge — see button flip to green footer)

# 6. Inspect DDB
make ddb-scan-acked          # only acknowledged rows
```

## Cost

| Component | Cost delta over Module 6 |
|---|---|
| Lambda invocations (few clicks/day) | $0 — deeply under free tier |
| Lambda Function URL | $0 — no additional charge, no API Gateway |
| DDB UpdateItem | $0 — PAY_PER_REQUEST at demo scale |
| EventBridge PutEvents (whitelisted only) | $0 — first 100 events/month free |

**Total marginal cost of Module 7.0: $0/month.**

## Tests

32 tests covering:

- `test_verify.py` (11) — valid sig, missing secret/ts/sig, non-integer ts, stale/future ts, wrong secret, body tampering, constant-time compare presence, `now_epoch` override.
- `test_persistence.py` (5) — kwargs shape, first ack, second-ack raises with prior, missing row raises CCF, atomic full round-trip.
- `test_slack.py` (7) — replace_original flag, action block stripped, footer names actor + time, `(already)` marker on replay path, non-actions blocks preserved verbatim, empty-blocks edge case, error toast is ephemeral.
- `test_bus.py` (5) — detail shape, happy PutEvents, soft-fail on bad bus name, stable constants, JSON-encodable detail.
- `test_handler.py` (11) — happy ack, bad sig → 401, stale ts → 401, double-click shows prior acker, unknown action_id → 200 empty, whitelisted reason path, non-whitelisted ack-only, missing incident → 500, malformed body → 400, config-missing-var, response body-shape assertions.

Run:

```bash
cd lambdas/remediator
poetry install --with dev
poetry run pytest -v
```

## Known limitations (deferred)

1. **Ack button is idempotent but not undoable.** No "Un-acknowledge" workflow. If someone acks by mistake, they'd have to `aws dynamodb update-item` manually. Fine for a demo; formal fix would be a second button + separate action_id.
2. **No actual remediation.** Module 7.1 lands the `kubectl patch` executor. Until then, `RemediationRequested` events land on the bus with no receiver.
3. **Single-region.** Function URL is regional. Multi-region ack routing would need Route53 latency-based DNS in front — massive over-engineering for a portfolio project.
4. **No Slack thread-reply.** Ack replaces the *original* message. Some teams prefer a threaded reply so the incident history stays visible. Config toggle in a future iteration.
