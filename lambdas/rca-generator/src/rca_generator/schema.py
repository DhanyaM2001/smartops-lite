"""Parser + validator for the IncidentDetected v1.0 event shape.

Contract source of truth: `docs/modules/04-controller.md` — event payload
section. Any breaking change to that shape MUST bump `schemaVersion` and
this module MUST grow a translator branch.

Design notes:
  - Frozen dataclass — accidental mutation between parse-time and
    DDB-write-time is impossible.
  - Every field maps 1:1 to a DDB attribute name. Keep the mapping stable.
  - Missing OPTIONAL fields become None; missing REQUIRED fields raise
    SchemaError so EventBridge retries the event (a corrupt event is more
    likely a bug than user error).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


SUPPORTED_SCHEMA_VERSIONS: tuple[str, ...] = ("1.0",)


class SchemaError(ValueError):
    """Raised when the event doesn't match the IncidentDetected contract."""


@dataclass(frozen=True, slots=True)
class Incident:
    """Parsed IncidentDetected payload (Module 4 schema v1.0)."""

    incident_id: str
    schema_version: str
    namespace: str
    pod_name: str
    pod_uid: str
    container_name: str
    reason: str
    restart_count: int
    node_name: str
    zone: str | None
    timestamp: str  # RFC3339 UTC
    message: str
    exit_code: int | None = None
    labels: dict[str, str] = field(default_factory=dict)


def parse_event(event: dict[str, Any], *, expected_schema: str = "1.0") -> Incident:
    """Extract + validate an Incident from a raw EventBridge event.

    Raises SchemaError with a specific field name on any problem.
    """
    if not isinstance(event, dict):
        raise SchemaError(f"event must be a dict, got {type(event).__name__}")

    # EventBridge envelope check
    source = event.get("source")
    if source != "smartops.controller":
        raise SchemaError(
            f"unexpected source {source!r} — expected 'smartops.controller'"
        )

    detail_type = event.get("detail-type")
    if detail_type != "IncidentDetected":
        raise SchemaError(
            f"unexpected detail-type {detail_type!r} — expected 'IncidentDetected'"
        )

    detail = event.get("detail")
    if not isinstance(detail, dict):
        raise SchemaError(
            f"event.detail must be an object, got {type(detail).__name__}"
        )

    # Schema-version gate — refuse to guess if the shape changed.
    got_version = detail.get("schemaVersion")
    if got_version not in SUPPORTED_SCHEMA_VERSIONS:
        raise SchemaError(
            f"unsupported schemaVersion {got_version!r}; "
            f"supported: {SUPPORTED_SCHEMA_VERSIONS}"
        )
    if got_version != expected_schema:
        # Not fatal — but flag it. The env var lets ops override 'expected'.
        pass

    # Required fields
    for required in (
        "incidentId",
        "namespace",
        "podName",
        "containerName",
        "reason",
        "timestamp",
    ):
        if detail.get(required) in (None, ""):
            raise SchemaError(f"detail.{required} is missing or empty")

    # Optional fields with sensible defaults
    labels_raw = detail.get("labels") or {}
    if not isinstance(labels_raw, dict):
        raise SchemaError(
            f"detail.labels must be an object, got {type(labels_raw).__name__}"
        )
    labels = {str(k): str(v) for k, v in labels_raw.items()}

    exit_code = detail.get("exitCode")
    if exit_code is not None:
        try:
            exit_code = int(exit_code)
        except (TypeError, ValueError) as e:
            raise SchemaError(f"detail.exitCode must be an int or null: {e}") from e

    try:
        restart_count = int(detail.get("restartCount") or 0)
    except (TypeError, ValueError) as e:
        raise SchemaError(f"detail.restartCount must be an int: {e}") from e

    return Incident(
        incident_id=str(detail["incidentId"]),
        schema_version=str(got_version),
        namespace=str(detail["namespace"]),
        pod_name=str(detail["podName"]),
        pod_uid=str(detail.get("podUid") or ""),
        container_name=str(detail["containerName"]),
        reason=str(detail["reason"]),
        restart_count=restart_count,
        node_name=str(detail.get("nodeName") or "unknown"),
        zone=(str(detail["zone"]) if detail.get("zone") else None),
        timestamp=str(detail["timestamp"]),
        message=str(detail.get("message") or ""),
        exit_code=exit_code,
        labels=labels,
    )
