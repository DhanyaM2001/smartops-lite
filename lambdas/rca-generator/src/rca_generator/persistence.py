"""DynamoDB writer for parsed incidents.

Design notes:
  - PutItem with ConditionExpression `attribute_not_exists(incidentId)`:
    genuinely idempotent-by-key. On a retry (EventBridge redelivery,
    Lambda internal retry, at-least-once delivery), the second PutItem
    is rejected with ConditionalCheckFailedException — which we swallow
    and treat as success. This is what protects the remediator's
    `rcaStatus=acknowledged` from being wiped by a late RCA retry.
  - `ingestedAt` field lets us distinguish "when the controller saw it"
    (`timestamp`) from "when the Lambda persisted it" (this field).
  - `rcaText` + `rcaStatus` are populated by the caller so Module 6's
    LLM output flows straight in. Module 5.0's placeholder is still the
    default when no RCA is supplied — DDB rows stay a stable shape.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

try:
    # botocore is available in the Lambda runtime + local dev env.
    from botocore.exceptions import ClientError  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover — fallback for envs without botocore
    ClientError = Exception  # type: ignore[assignment,misc]

from rca_generator.schema import Incident

log = logging.getLogger(__name__)


RCA_PLACEHOLDER = "RCA pending — LLM disabled or upstream failure."


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def build_item(
    incident: Incident,
    *,
    now_iso: str | None = None,
    rca_text: str | None = None,
    rca_status: str = "pending",
    rca_source: str = "none",
) -> dict[str, Any]:
    """Shape the DDB row. Extracted so tests can assert without mocking boto3.

    `rca_text=None` falls back to the placeholder + `rcaStatus="pending"`.
    Module 5.0-compatible: not passing any RCA kwargs yields the exact same
    row shape as Module 5.0.
    """
    return {
        "incidentId": incident.incident_id,
        "schemaVersion": incident.schema_version,
        "namespace": incident.namespace,
        "podName": incident.pod_name,
        "podUid": incident.pod_uid,
        "containerName": incident.container_name,
        "reason": incident.reason,
        "restartCount": incident.restart_count,
        "nodeName": incident.node_name,
        "zone": incident.zone,
        "timestamp": incident.timestamp,
        "message": incident.message,
        "exitCode": incident.exit_code,
        "labels": incident.labels,
        # Lambda-added fields
        "ingestedAt": now_iso or _now_iso(),
        "rcaText": rca_text if rca_text else RCA_PLACEHOLDER,
        "rcaStatus": rca_status,
        "rcaSource": rca_source,
    }


def persist(
    incident: Incident,
    *,
    table_name: str,
    ddb_client,
    rca_text: str | None = None,
    rca_status: str = "pending",
    rca_source: str = "none",
) -> dict[str, Any]:
    """PutItem into DynamoDB. Returns the raw response for logging."""
    item = build_item(
        incident,
        rca_text=rca_text,
        rca_status=rca_status,
        rca_source=rca_source,
    )
    marshalled = _marshall(item)
    try:
        resp = ddb_client.put_item(
            TableName=table_name,
            Item=marshalled,
            # If the row already exists (retry of an already-processed event),
            # DO NOT overwrite it — the remediator may have added
            # rcaStatus=acknowledged, acknowledgedBy, acknowledgedAt after
            # the first write. A blind PutItem would erase all of that.
            ConditionExpression="attribute_not_exists(incidentId)",
        )
    except ClientError as e:
        code = e.response.get("Error", {}).get("Code", "") if hasattr(e, "response") else ""
        if code == "ConditionalCheckFailedException":
            # Idempotent no-op: the incident is already in the table.
            log.info(
                "incident already persisted (idempotent retry, no overwrite)",
                extra={
                    "incident_id": incident.incident_id,
                    "table": table_name,
                    "reason": incident.reason,
                    "namespace": incident.namespace,
                },
            )
            return {"idempotent": True}
        raise
    log.info(
        "persisted incident",
        extra={
            "incident_id": incident.incident_id,
            "table": table_name,
            "reason": incident.reason,
            "namespace": incident.namespace,
            "rca_status": rca_status,
            "rca_source": rca_source,
        },
    )
    return resp


def _marshall(item: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Low-level DynamoDB attribute-value marshaller for the shape we write."""
    out: dict[str, dict[str, Any]] = {}
    for k, v in item.items():
        out[k] = _to_attr_value(v)
    return out


def _to_attr_value(v: Any) -> dict[str, Any]:
    if v is None:
        return {"NULL": True}
    if isinstance(v, bool):
        return {"BOOL": v}
    if isinstance(v, int):
        return {"N": str(v)}
    if isinstance(v, str):
        return {"S": v} if v else {"NULL": True}
    if isinstance(v, dict):
        return {"M": {str(k): _to_attr_value(x) for k, x in v.items()}}
    if isinstance(v, list):
        return {"L": [_to_attr_value(x) for x in v]}
    log.warning("unmarshallable type %s — coercing to string", type(v).__name__)
    return {"S": str(v)}
