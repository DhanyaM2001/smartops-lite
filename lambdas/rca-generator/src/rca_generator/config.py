"""Runtime configuration + lazy secret loading.

Called once at cold start. Fetching secrets here (instead of every
invocation) keeps hot-path latency near zero and avoids Parameter Store
throughput limits under load.
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
    ssm_slack_webhook_path: str
    ssm_groq_key_path: str
    slack_enabled: bool
    slack_blocks_enabled: bool  # Module 6
    llm_enabled: bool  # Module 6
    llm_model: str  # Module 6
    llm_timeout_seconds: int  # Module 6
    llm_max_tokens: int  # Module 6
    log_level: str
    schema_version_expected: str
    aws_region: str

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            incidents_table_name=_required("INCIDENTS_TABLE_NAME"),
            ssm_slack_webhook_path=_required("SSM_SLACK_WEBHOOK_PATH"),
            ssm_groq_key_path=os.getenv("SSM_GROQ_KEY_PATH", ""),
            slack_enabled=_bool("SLACK_ENABLED", default=True),
            slack_blocks_enabled=_bool("SLACK_BLOCKS_ENABLED", default=True),
            llm_enabled=_bool("LLM_ENABLED", default=True),
            llm_model=os.getenv("LLM_MODEL", "qwen/qwen3.8-27b"),
            llm_timeout_seconds=int(os.getenv("LLM_TIMEOUT_SECONDS", "10")),
            llm_max_tokens=int(os.getenv("LLM_MAX_TOKENS", "200")),
            log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
            schema_version_expected=os.getenv("SCHEMA_VERSION_EXPECTED", "1.0"),
            aws_region=os.getenv("AWS_REGION", "ap-south-1"),
        )


def _required(name: str) -> str:
    v = os.getenv(name)
    if not v:
        raise RuntimeError(f"required env var {name!r} is unset")
    return v


def _bool(name: str, *, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in ("true", "1", "yes", "on")


@dataclass(frozen=True)
class Secrets:
    """Values fetched from SSM SecureString at cold start.

    We tolerate missing values here (e.g. Slack webhook not stored yet):
    the caller decides whether to fail-soft or fail-hard.
    """

    slack_webhook_url: str | None
    groq_api_key: str | None

    @classmethod
    def load(cls, cfg: Config, ssm_client) -> "Secrets":
        """Fetch both parameters in ONE GetParameters call — cheaper + faster."""
        names = [cfg.ssm_slack_webhook_path]
        if cfg.ssm_groq_key_path:
            names.append(cfg.ssm_groq_key_path)

        resp = ssm_client.get_parameters(Names=names, WithDecryption=True)

        got: dict[str, str] = {p["Name"]: p["Value"] for p in resp.get("Parameters", [])}
        missing = resp.get("InvalidParameters", [])
        if missing:
            log.warning("ssm parameters missing", extra={"missing": missing, "asked_for": names})

        return cls(
            slack_webhook_url=got.get(cfg.ssm_slack_webhook_path),
            groq_api_key=got.get(cfg.ssm_groq_key_path) if cfg.ssm_groq_key_path else None,
        )
