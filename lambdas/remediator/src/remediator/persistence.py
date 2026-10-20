"""DynamoDB update: mark an incident acknowledged.

Uses a conditional UpdateItem so we can distinguish these three cases
in the response to the user:

  1. **First ack**            → update succeeds
  2. **Already-acknowledged** → update fails (`ConditionalCheckFailed`)
                                — we return the existing ack info so the
                                Slack message still shows *who* did it
  3. **Row doesn't exist**    → update fails (`ValidationException`) —
                                caller returns 500 (bug: shouldn't happen)

`build_update_expression()` is separated out so the marshalling logic can
be unit-tested without DynamoDB.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

log = logging.getLogger(__name__)


class AlreadyAcknowledged(Exception):
    """Raised when the incident was already acknowledged. Carries prior actor."""

    def __init__(self, actor: str, when: str) -> None:
        super().__init__(f"already acknowledged by {actor} at {when}")
        self.actor = actor
        self.when = when


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def build_update_kwargs(
    *,
    incident_id: str,
    actor: str,
    now_iso: str | None = None,
) -> dict[str, Any]:
    """Extracted for testability — returns the boto3 UpdateItem kwargs shape."""
    when = now_iso or _now_iso()
    return {
        "Key": {"incidentId": {"S": incident_id}},
        "UpdateExpression": (
            "SET rcaStatus = :ack, acknowledgedBy = :who, acknowledgedAt = :when"
        ),
        "ConditionExpression": (
            "attribute_exists(incidentId) AND "
            "(attribute_not_exists(rcaStatus) OR rcaStatus <> :ack)"
        ),
        "ExpressionAttributeValues": {
            ":ack":  {"S": "acknowledged"},
            ":who":  {"S": actor},
            ":when": {"S": when},
        },
        "ReturnValues": "ALL_NEW",
    }


def acknowledge(
    *,
    incident_id: str,
    actor: str,
    table_name: str,
    ddb_client,
    now_iso: str | None = None,
) -> dict[str, Any]:
    """Mark the incident acknowledged. Raise AlreadyAcknowledged on retry."""
    kwargs = build_update_kwargs(incident_id=incident_id, actor=actor, now_iso=now_iso)
    try:
        resp = ddb_client.update_item(TableName=table_name, **kwargs)
    except ddb_client.exceptions.ConditionalCheckFailedException as e:
        # Fetch the row so we can tell the user WHO did it first.
        prior = _read_prior_ack(ddb_client, table_name, incident_id)
        if prior:
            raise AlreadyAcknowledged(**prior) from e
        raise

    attrs = resp.get("Attributes", {})
    log.info("incident acknowledged", extra={
        "incident_id": incident_id,
        "actor": actor,
        "prior_status": attrs.get("rcaStatus", {}).get("S"),
    })
    return _unmarshall(attrs)


def _read_prior_ack(ddb_client, table_name: str, incident_id: str) -> dict[str, str] | None:
    """Fetch existing ack info so we can echo it back on double-click."""
    try:
        row = ddb_client.get_item(
            TableName=table_name,
            Key={"incidentId": {"S": incident_id}},
        )
    except Exception as e:  # noqa: BLE001 — best-effort read
        log.warning("prior-ack read failed", extra={
            "incident_id": incident_id, "error": str(e),
        })
        return None
    item = row.get("Item") or {}
    who = item.get("acknowledgedBy", {}).get("S")
    when = item.get("acknowledgedAt", {}).get("S")
    if who and when:
        return {"actor": who, "when": when}
    return None


def _unmarshall(av: dict[str, Any]) -> dict[str, Any]:
    """Best-effort DDB attribute-value → plain-Python dict (just what we need)."""
    out: dict[str, Any] = {}
    for k, v in av.items():
        if "S" in v: out[k] = v["S"]
        elif "N" in v: out[k] = int(v["N"]) if v["N"].isdigit() else float(v["N"])
        elif "BOOL" in v: out[k] = v["BOOL"]
        elif "NULL" in v: out[k] = None
        else: out[k] = v  # leave raw
    return out
