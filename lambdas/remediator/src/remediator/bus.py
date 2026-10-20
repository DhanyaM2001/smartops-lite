"""EventBridge publisher for RemediationRequested events (Module 7.0 → 7.1).

We emit a follow-up event ONLY for whitelisted reasons — Module 7.0 is
"ack + track", not "remediate". The event is a hook for Module 7.1 (or
the controller) to subscribe to and actually mutate cluster state.

Fail-soft: if PutEvents fails, the acknowledgement was already persisted
to DDB and Slack was already updated — losing the bus event just means
7.1's executor won't fire this time. It does NOT roll back the ack.
"""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import Any

log = logging.getLogger(__name__)

EVENT_SOURCE = "smartops.remediator"
DETAIL_TYPE = "RemediationRequested"
SCHEMA_VERSION = "1.0"


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def build_detail(
    *,
    incident_id: str,
    reason: str,
    actor: str,
    incident_row: dict[str, Any],
    now_iso: str | None = None,
) -> dict[str, Any]:
    """Payload shape — versioned v1.0 so Module 7.1 can pin against it."""
    return {
        "schemaVersion": SCHEMA_VERSION,
        "incidentId": incident_id,
        "reason": reason,
        "requestedBy": actor,
        "requestedAt": now_iso or _now_iso(),
        "namespace": incident_row.get("namespace"),
        "podName": incident_row.get("podName"),
        "containerName": incident_row.get("containerName"),
    }


def request_remediation(
    *,
    incident_id: str,
    reason: str,
    actor: str,
    incident_row: dict[str, Any],
    event_bus_name: str,
    events_client,
) -> bool:
    """PutEvents onto the SmartOps bus. Returns True on success, False on soft-fail."""
    detail = build_detail(
        incident_id=incident_id, reason=reason, actor=actor, incident_row=incident_row
    )
    try:
        resp = events_client.put_events(
            Entries=[
                {
                    "Source": EVENT_SOURCE,
                    "DetailType": DETAIL_TYPE,
                    "Detail": json.dumps(detail),
                    "EventBusName": event_bus_name,
                }
            ]
        )
    except Exception as e:  # noqa: BLE001 — bus failure is soft
        log.warning("bus publish failed (soft)", extra={
            "incident_id": incident_id, "error": str(e),
        })
        return False

    failed = resp.get("FailedEntryCount", 0)
    if failed:
        log.warning("bus put_events reported failures", extra={
            "incident_id": incident_id, "failed": failed, "entries": resp.get("Entries"),
        })
        return False

    log.info("remediation requested", extra={
        "incident_id": incident_id, "reason": reason, "actor": actor,
    })
    return True
