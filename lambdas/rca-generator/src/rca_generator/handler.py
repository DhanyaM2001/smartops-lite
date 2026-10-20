"""Lambda entry point — wires config → parse → LLM → persist → notify.

Invoked ONCE per EventBridge event (no batching).

Fail policy (unchanged from Module 5.0 for parse + persist; new for LLM
and Slack):
  - **Parse error** → RAISE (EventBridge retries; malformed events are bugs).
  - **LLM failure** → SOFT: fall back to placeholder text, still persist + notify.
  - **DDB write failure** → RAISE (we want the retry; incident MUST land).
  - **Slack failure** → SOFT: DDB is already written, notification lost.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

from rca_generator import rca_llm, slack_blocks
from rca_generator.config import Config, Secrets
from rca_generator.notifier import build_plaintext_message, send_payload
from rca_generator.persistence import persist
from rca_generator.schema import parse_event

# ---- Structured logger setup (runs at COLD START only) --------------------
log = logging.getLogger()
_log_level = os.getenv("LOG_LEVEL", "INFO").upper()
log.setLevel(_log_level)


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


# ---- Cold-start init (module-scope, runs ONCE per container) -------------
_CONFIG: Config | None = None
_SECRETS: Secrets | None = None
_DDB = None
_SSM = None


def _init() -> tuple[Config, Secrets, Any]:
    """Lazy init — first invocation pays the cost, later ones reuse."""
    global _CONFIG, _SECRETS, _DDB, _SSM
    if _CONFIG is None:
        _CONFIG = Config.from_env()
    if _SSM is None or _DDB is None:
        import boto3

        _SSM = boto3.client("ssm", region_name=_CONFIG.aws_region)
        _DDB = boto3.client("dynamodb", region_name=_CONFIG.aws_region)
    if _SECRETS is None:
        _SECRETS = Secrets.load(_CONFIG, _SSM)
    return _CONFIG, _SECRETS, _DDB


def lambda_handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    """AWS Lambda entry point."""
    cfg, secrets, ddb = _init()

    log.info("handler start", extra={
        "event_id": event.get("id"),
        "detail_type": event.get("detail-type"),
        "source": event.get("source"),
    })

    # 1. Parse — schema error is FATAL (raise → EventBridge retries).
    incident = parse_event(event, expected_schema=cfg.schema_version_expected)

    # 2. LLM (Module 6) — fail-soft. On failure, fall through to placeholder.
    rca_text: str | None = None
    rca_source = "none"
    if cfg.llm_enabled and secrets.groq_api_key:
        rca_text = rca_llm.generate_rca(
            incident,
            api_key=secrets.groq_api_key,
            model=cfg.llm_model,
            timeout_seconds=cfg.llm_timeout_seconds,
            max_tokens=cfg.llm_max_tokens,
        )
        rca_source = "groq" if rca_text else "fallback"

    rca_status = "generated" if rca_text else "pending"

    # 3. Persist to DynamoDB. If this fails we WANT the retry.
    persist(
        incident,
        table_name=cfg.incidents_table_name,
        ddb_client=ddb,
        rca_text=rca_text,
        rca_status=rca_status,
        rca_source=rca_source,
    )

    # 4. Slack ping — fail-soft, never blocks DDB write.
    slack_sent = False
    if cfg.slack_enabled:
        slack_sent = _send_slack(
            incident,
            rca_text=rca_text,
            rca_source=rca_source,
            webhook_url=secrets.slack_webhook_url,
            blocks_enabled=cfg.slack_blocks_enabled,
        )

    log.info("handler done", extra={
        "incident_id": incident.incident_id,
        "reason": incident.reason,
        "persisted": True,
        "rca_status": rca_status,
        "rca_source": rca_source,
        "slack_sent": slack_sent,
    })
    return {
        "statusCode": 200,
        "incidentId": incident.incident_id,
        "persisted": True,
        "rcaStatus": rca_status,
        "rcaSource": rca_source,
        "slackSent": slack_sent,
    }


def _send_slack(
    incident,  # type: ignore[no-untyped-def]
    *,
    rca_text: str | None,
    rca_source: str,
    webhook_url: str | None,
    blocks_enabled: bool,
) -> bool:
    """Choose Block Kit or plain text and dispatch. Fail-soft either way."""
    if blocks_enabled:
        payload = slack_blocks.build_payload(
            incident,
            rca_text=rca_text or "RCA unavailable (LLM disabled or failed).",
            rca_source=rca_source,
        )
    else:
        payload = {"text": build_plaintext_message(incident)}
    return send_payload(payload, webhook_url=webhook_url, incident_id=incident.incident_id)


def _reset_for_tests() -> None:
    """Reset module-level state (test-only helper)."""
    global _CONFIG, _SECRETS, _DDB, _SSM
    _CONFIG = None
    _SECRETS = None
    _DDB = None
    _SSM = None
