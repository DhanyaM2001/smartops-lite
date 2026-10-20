"""Runtime config + cold-start secret loading.

Mirrors the pattern from `rca_generator.config`:
  - Non-secret operational knobs live in Lambda env vars (from Terraform).
  - Secrets live in SSM SecureString, fetched ONCE at cold start in a
    single `GetParameters` call.
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
    ssm_slack_signing_secret_path: str
    event_bus_name: str
    allowed_remediation_reasons: frozenset[str]
    replay_window_seconds: int
    log_level: str
    aws_region: str

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            incidents_table_name=_required("INCIDENTS_TABLE_NAME"),
            ssm_slack_signing_secret_path=_required("SSM_SLACK_SIGNING_SECRET_PATH"),
            event_bus_name=_required("EVENT_BUS_NAME"),
            allowed_remediation_reasons=_reasons("ALLOWED_REMEDIATION_REASONS"),
            replay_window_seconds=int(os.getenv("REPLAY_WINDOW_SECONDS", "300")),
            log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
            aws_region=os.getenv("AWS_REGION", "ap-south-1"),
        )


def _required(name: str) -> str:
    v = os.getenv(name)
    if not v:
        raise RuntimeError(f"required env var {name!r} is unset")
    return v


def _reasons(name: str) -> frozenset[str]:
    raw = os.getenv(name, "").strip()
    if not raw:
        return frozenset()
    return frozenset(r.strip() for r in raw.split(",") if r.strip())


@dataclass(frozen=True)
class Secrets:
    """SSM SecureString values fetched at cold start."""

    slack_signing_secret: str | None

    @classmethod
    def load(cls, cfg: Config, ssm_client) -> "Secrets":
        resp = ssm_client.get_parameters(
            Names=[cfg.ssm_slack_signing_secret_path],
            WithDecryption=True,
        )
        got = {p["Name"]: p["Value"] for p in resp.get("Parameters", [])}
        missing = resp.get("InvalidParameters", [])
        if missing:
            log.warning("ssm parameters missing", extra={"missing": missing})
        return cls(slack_signing_secret=got.get(cfg.ssm_slack_signing_secret_path))
