"""Lambda entry point — Slack interaction receiver (Module 7.0).

Flow, per invocation:
  1. Decode the Lambda Function URL invocation event.
  2. Verify Slack HMAC signature (401 on failure — Slack auto-retries).
  3. Parse `payload=<url-encoded JSON>` from body.
  4. Assert `action_id == "smartops_acknowledge"`.
  5. Update DDB (`rcaStatus=acknowledged` + who/when). AlreadyAcknowledged
     is a HAPPY path — we still update Slack and skip the bus event.
  6. If reason is in `ALLOWED_REMEDIATION_REASONS`, PutEvents onto bus
     (soft-fail).
  7. Return a JSON body that replaces the original Slack message with an
     "✔ Acknowledged" footer.

Every error path is logged with structured fields. Signature/parse
errors do NOT return detail to the caller — potential info leak.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import urllib.parse
from typing import Any

from remediator import bus, slack, verify
from remediator.config import Config, Secrets
from remediator.persistence import AlreadyAcknowledged, acknowledge

# ---- Structured JSON logger (cold-start only) --------------------------
log = logging.getLogger()
log.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())


class _JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for k, v in record.__dict__.items():
            if k in payload or k in _LOG_RESERVED:
                continue
            payload[k] = v
        return json.dumps(payload, default=str)


_LOG_RESERVED = {
    "name", "msg", "args", "levelname", "levelno", "pathname", "filename",
    "module", "exc_info", "exc_text", "stack_info", "lineno", "funcName",
    "created", "msecs", "relativeCreated", "thread", "threadName",
    "processName", "process", "message", "asctime", "taskName",
}


for _h in log.handlers:
    _h.setFormatter(_JsonFormatter())
if not log.handlers:
    _sh = logging.StreamHandler()
    _sh.setFormatter(_JsonFormatter())
    log.addHandler(_sh)


# ---- Cold-start init (module-scope) ------------------------------------
_CONFIG: Config | None = None
_SECRETS: Secrets | None = None
_DDB = None
_SSM = None
_EVENTS = None


def _init():  # -> tuple, but typed loosely for boto3 clients
    global _CONFIG, _SECRETS, _DDB, _SSM, _EVENTS
    if _CONFIG is None:
        _CONFIG = Config.from_env()
    if _SSM is None or _DDB is None or _EVENTS is None:
        import boto3

        _SSM = boto3.client("ssm", region_name=_CONFIG.aws_region)
        _DDB = boto3.client("dynamodb", region_name=_CONFIG.aws_region)
        _EVENTS = boto3.client("events", region_name=_CONFIG.aws_region)
    if _SECRETS is None:
        _SECRETS = Secrets.load(_CONFIG, _SSM)
    return _CONFIG, _SECRETS, _DDB, _EVENTS


# ---- Response helpers ---------------------------------------------------
def _http(status: int, body: dict[str, Any] | str = "") -> dict[str, Any]:
    if isinstance(body, dict):
        return {
            "statusCode": status,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body),
        }
    return {"statusCode": status, "body": body}


# ---- Entry point --------------------------------------------------------
def lambda_handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    cfg, secrets, ddb, events_client = _init()

    # 1. Extract raw body + headers (Lambda Function URL payload v2.0).
    raw_body = _decode_body(event)
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}

    # 2. HMAC verify — must happen BEFORE parsing anything.
    try:
        verify.verify(
            raw_body=raw_body,
            timestamp_header=headers.get("x-slack-request-timestamp"),
            signature_header=headers.get("x-slack-signature"),
            signing_secret=secrets.slack_signing_secret,
            replay_window_seconds=cfg.replay_window_seconds,
        )
    except verify.VerificationError as e:
        log.warning("signature verification failed", extra={"reason": str(e)})
        return _http(401, "unauthorized")

    # 3. Parse `payload=<url-encoded JSON>`.
    try:
        payload = _parse_payload(raw_body)
    except (KeyError, json.JSONDecodeError, ValueError) as e:
        log.warning("payload parse failed", extra={"error": str(e)})
        return _http(400, "bad request")

    # 4. Extract the action.
    try:
        action = payload["actions"][0]
        action_id = action["action_id"]
        incident_id = action["value"]
        actor = payload["user"]["id"]
        original_message = payload.get("message") or {}
    except (KeyError, IndexError) as e:
        log.warning("payload missing action fields", extra={"error": str(e)})
        return _http(400, "bad request")

    if action_id != "smartops_acknowledge":
        log.info("unknown action_id — ignoring", extra={"action_id": action_id})
        return _http(200, "")  # Slack accepts empty body

    # 5. Update DDB — conditional so double-clicks show the ORIGINAL acker.
    try:
        row = acknowledge(
            incident_id=incident_id,
            actor=actor,
            table_name=cfg.incidents_table_name,
            ddb_client=ddb,
        )
    except AlreadyAcknowledged as prior:
        log.info("already acknowledged", extra={
            "incident_id": incident_id, "prior_actor": prior.actor, "prior_when": prior.when,
        })
        body = slack.build_already_ack_response(
            original_message=original_message,
            prior_actor=prior.actor,
            prior_when=prior.when,
        )
        return _http(200, body)
    except Exception as e:  # noqa: BLE001
        log.error("ddb ack failed", extra={"incident_id": incident_id, "error": str(e)})
        return _http(500, slack.build_error_response())

    # 6. Whitelisted-reason bonus: fire RemediationRequested onto the bus.
    reason = str(row.get("reason") or "")
    if reason in cfg.allowed_remediation_reasons:
        bus.request_remediation(
            incident_id=incident_id,
            reason=reason,
            actor=actor,
            incident_row=row,
            event_bus_name=cfg.event_bus_name,
            events_client=events_client,
        )
    else:
        log.info("reason not whitelisted for remediation — ack only", extra={
            "incident_id": incident_id, "reason": reason,
            "allowed": sorted(cfg.allowed_remediation_reasons),
        })

    # 7. Reply to Slack: replace the button with an "✔ Acknowledged" footer.
    when = str(row.get("acknowledgedAt") or "")
    body = slack.build_ack_response(
        original_message=original_message, actor=actor, when=when
    )
    return _http(200, body)


# ---- Body decoding ------------------------------------------------------
def _decode_body(event: dict[str, Any]) -> bytes:
    """Lambda URL sends body as str; base64-encoded when binary. We need bytes."""
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        return base64.b64decode(raw)
    return raw.encode("utf-8")


def _parse_payload(raw_body: bytes) -> dict[str, Any]:
    """Slack sends `payload=<url-encoded JSON>` as form-encoded body."""
    body_str = raw_body.decode("utf-8")
    form = urllib.parse.parse_qs(body_str, strict_parsing=False)
    payloads = form.get("payload")
    if not payloads:
        raise KeyError("payload")
    return json.loads(payloads[0])


def _reset_for_tests() -> None:
    """Test-only helper — clear module-scope state between fixtures."""
    global _CONFIG, _SECRETS, _DDB, _SSM, _EVENTS
    _CONFIG = None
    _SECRETS = None
    _DDB = None
    _SSM = None
    _EVENTS = None
