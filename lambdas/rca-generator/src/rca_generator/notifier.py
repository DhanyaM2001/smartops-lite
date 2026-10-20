"""Slack webhook client — stdlib only.

Supports two payload shapes:
  - **Block Kit (Module 6)** — rich card with severity color, context row,
    RCA text, and an Acknowledge button. `send_blocks(payload)` takes an
    already-built payload from `slack_blocks.build_payload()`.
  - **Plain text (Module 5.0 legacy path)** — one-line fallback used when
    Block Kit isn't wanted (e.g. `SLACK_BLOCKS_ENABLED=false`).

Both paths fail-SOFT: any HTTP or network error is logged but never
raised. A Slack outage cannot block a DDB write.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from typing import Any

from rca_generator.schema import Incident

log = logging.getLogger(__name__)


HTTP_TIMEOUT_SECONDS = 5


def build_plaintext_message(incident: Incident) -> str:
    """Module 5.0 fallback format — retained so `SLACK_BLOCKS_ENABLED=false` still works."""
    parts = [
        f":rotating_light: *SmartOps incident* — `{incident.reason}`",
        f"pod `{incident.namespace}/{incident.pod_name}` container `{incident.container_name}`",
        f"restarts={incident.restart_count} node=`{incident.node_name}`",
    ]
    if incident.zone:
        parts.append(f"zone=`{incident.zone}`")
    if incident.exit_code is not None:
        parts.append(f"exit_code={incident.exit_code}")
    parts.append(f"_incident id: `{incident.incident_id}`_")
    return "\n".join(parts)


# Kept for backwards-compat with Module 5.0 tests. New code paths should
# use `send_payload()` with a Block Kit dict.
def build_message(incident: Incident) -> str:
    return build_plaintext_message(incident)


def notify(incident: Incident, *, webhook_url: str | None) -> bool:
    """Legacy plain-text send (Module 5.0). Kept for backward-compat."""
    if not webhook_url:
        log.info("slack disabled or webhook missing — skipping", extra={
            "incident_id": incident.incident_id,
        })
        return False
    return send_payload(
        {"text": build_plaintext_message(incident)},
        webhook_url=webhook_url,
        incident_id=incident.incident_id,
    )


def send_payload(
    payload: dict[str, Any],
    *,
    webhook_url: str | None,
    incident_id: str = "",
) -> bool:
    """POST an already-built payload (plain or Block Kit) to Slack. Fail-soft."""
    if not webhook_url:
        log.info("slack disabled or webhook missing — skipping", extra={
            "incident_id": incident_id,
        })
        return False

    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        webhook_url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_SECONDS) as resp:
            status = resp.status
            if 200 <= status < 300:
                log.info("slack notified", extra={
                    "incident_id": incident_id, "status": status, "bytes": len(body),
                })
                return True
            log.warning("slack non-2xx", extra={
                "incident_id": incident_id, "status": status,
            })
            return False
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
        log.warning("slack call failed (soft)", extra={
            "incident_id": incident_id, "error": str(e),
        })
        return False
