"""Lambda entry point — EventBridge schedule → DDB scan → aggregate → publish.

Cold-start-only init of Config + boto3 clients keeps hot-path latency near
zero. `_reset_for_tests()` lets pytest inject moto clients.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

from mttr_aggregator import aggregator, ddb_reader, publisher
from mttr_aggregator.config import Config

log = logging.getLogger()
log.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())


# ---- Structured JSON logging (matches rca-generator + remediator + controller)
# One event per line; the `extra=` kwarg merges into the top-level object so
# CloudWatch Logs Insights can filter on any structured field.
_LOG_RESERVED = {
    "name", "msg", "args", "levelname", "levelno", "pathname", "filename",
    "module", "exc_info", "exc_text", "stack_info", "lineno", "funcName",
    "created", "msecs", "relativeCreated", "thread", "threadName",
    "processName", "process", "message", "asctime", "taskName",
}


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


for _h in log.handlers:
    _h.setFormatter(_JsonFormatter())
if not log.handlers:
    _sh = logging.StreamHandler()
    _sh.setFormatter(_JsonFormatter())
    log.addHandler(_sh)

# Module-scope singletons — populated on first invocation (cold start).
_CONFIG: Config | None = None
_DDB: Any = None
_CW: Any = None


def _init() -> tuple[Config, Any, Any]:
    """Cold-start init. Idempotent — safe to call every invocation."""
    global _CONFIG, _DDB, _CW  # noqa: PLW0603
    if _CONFIG is None:
        _CONFIG = Config.from_env()
    if _DDB is None:
        import boto3
        _DDB = boto3.client("dynamodb", region_name=_CONFIG.aws_region)
    if _CW is None:
        import boto3
        _CW = boto3.client("cloudwatch", region_name=_CONFIG.aws_region)
    return _CONFIG, _DDB, _CW


def _reset_for_tests() -> None:
    """Test-only: clear module-scope singletons so a fresh cold-start runs."""
    global _CONFIG, _DDB, _CW  # noqa: PLW0603
    _CONFIG = None
    _DDB = None
    _CW = None


def _now_from_event(event: dict[str, Any]) -> datetime:
    """Prefer the EventBridge `time` field over wall clock.

    EventBridge scheduled events always carry a `time` (ISO 8601 UTC)
    field marking the schedule tick. Using it gives us:
      - Deterministic aggregation windows aligned to the schedule.
      - Trivial testability (pytest just passes `{"time": "..."}`).

    Falls back to `datetime.now(timezone.utc)` if the field is missing or
    unparseable (e.g. manual invoke with an empty payload).
    """
    ts = event.get("time")
    if isinstance(ts, str):
        try:
            if ts.endswith("Z"):
                ts = ts[:-1] + "+00:00"
            dt = datetime.fromisoformat(ts)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except (ValueError, TypeError):
            pass
    return datetime.now(timezone.utc)


def lambda_handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    """Entry point.

    Event is the EventBridge scheduled event envelope. We read `event["time"]`
    (schedule tick) if present; otherwise we fall back to wall-clock now.
    Returns a JSON summary for CloudWatch Logs.
    """
    cfg, ddb, cw = _init()
    now_utc = _now_from_event(event or {})

    log.info(
        "aggregation start",
        extra={
            "table": cfg.incidents_table_name,
            "window_minutes": cfg.window_minutes,
            "namespace": cfg.metric_namespace,
        },
    )

    rows = ddb_reader.scan_recent(
        table_name=cfg.incidents_table_name,
        ddb_client=ddb,
        window_minutes=cfg.window_minutes,
        now_utc=now_utc,
    )

    metrics = aggregator.aggregate(rows, now_utc=now_utc)

    published = publisher.publish(
        metrics,
        namespace=cfg.metric_namespace,
        cloudwatch_client=cw,
        timestamp=now_utc,
    )

    result = {
        "statusCode": 200,
        "rowsScanned": len(rows),
        "metricsComputed": len(metrics),
        "metricsPublished": published,
        "window_minutes": cfg.window_minutes,
    }
    log.info("aggregation done", extra=result)
    return result
