"""Runtime config — loaded once at cold start from Lambda env vars.

Non-secret only. No SSM calls needed (aggregator has zero secrets — it only
reads DDB and writes CloudWatch metrics).
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass

log = logging.getLogger(__name__)


@dataclass(frozen=True)
class Config:
    """Non-secret runtime config sourced from Lambda env vars."""

    incidents_table_name: str
    metric_namespace: str
    window_minutes: int
    log_level: str
    aws_region: str

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            incidents_table_name=_required("INCIDENTS_TABLE_NAME"),
            metric_namespace=os.getenv("METRIC_NAMESPACE", "SmartOps"),
            window_minutes=int(os.getenv("WINDOW_MINUTES", "60")),
            log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
            aws_region=os.getenv("AWS_REGION", "ap-south-1"),
        )


def _required(name: str) -> str:
    v = os.getenv(name)
    if not v:
        raise RuntimeError(f"required env var {name!r} is unset")
    return v
