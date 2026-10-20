"""Publish incidents to AWS EventBridge (or stdout in dry-run mode).

Isolates all AWS SDK usage so the WATCHER + DETECTOR can be tested without
mocking boto3. The publisher is the ONLY module in this package that
imports boto3.
"""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:  # pragma: no cover
    from smartops_controller.detector import Incident

log = logging.getLogger(__name__)


class Publisher(Protocol):
    """Duck-typed interface — WATCHER only depends on this."""

    def publish(self, incident: Incident) -> None:  # pragma: no cover
        ...


class DryRunPublisher:
    """Writes the JSON payload to stdout via the logger. No AWS calls.

    Used by the local kind demo path (`DRY_RUN=true`) so reviewers can see
    the whole pipeline work without an AWS account.
    """

    def __init__(self, event_bus_name: str) -> None:
        self.event_bus_name = event_bus_name

    def publish(self, incident: Incident) -> None:
        log.info(
            "dry-run publish",
            extra={
                "target_bus": self.event_bus_name,
                "detail_type": "IncidentDetected",
                "source": "smartops.controller",
                "detail": incident.to_dict(),
            },
        )


class EventBridgePublisher:
    """Real EventBridge PutEvents call.

    The boto3 client picks up credentials from the standard chain:
    env vars → shared credentials file → EC2 IMDS (in-cluster) → ECS/EKS
    task role. In our K3s setup, the credentials come from the node's
    EC2 IAM role via IMDS (see docs/modules/04-controller.md for why we
    chose node IAM over IRSA).
    """

    def __init__(self, event_bus_name: str, region: str) -> None:
        self.event_bus_name = event_bus_name
        # Deferred import — keeps `moto`-based tests fast when they patch boto3.
        import boto3

        self._client = boto3.client("events", region_name=region)

    def publish(self, incident: Incident) -> None:
        entry = {
            "Source": "smartops.controller",
            "DetailType": "IncidentDetected",
            "Detail": json.dumps(incident.to_dict(), default=str),
            "EventBusName": self.event_bus_name,
        }
        try:
            resp = self._client.put_events(Entries=[entry])
        except Exception as e:
            # botocore ClientError (bus not found, throttle, network, IAM)
            # bubbles up here. Wrap so the watcher's error handler sees a
            # single, well-typed exception rather than the raw boto3 shape.
            log.error(
                "eventbridge put_events call failed",
                extra={
                    "incident_id": incident.incident_id,
                    "target_bus": self.event_bus_name,
                    "error": str(e),
                    "error_type": type(e).__name__,
                },
            )
            raise PublishError(f"put_events failed: {e}") from e
        failed = int(resp.get("FailedEntryCount", 0))
        if failed:
            # EventBridge accepts the request but per-entry failures are
            # reported in the Entries array. Log details and let the watcher
            # decide what to do (we don't retry inside publisher — the K8s
            # watch will re-emit the same pod event if we crash-loop).
            errors = [e for e in resp.get("Entries", []) if "ErrorCode" in e]
            log.error(
                "eventbridge put_events partial failure",
                extra={
                    "failed_count": failed,
                    "errors": errors,
                    "incident_id": incident.incident_id,
                },
            )
            raise PublishError(f"EventBridge rejected {failed} entry(ies): {errors}")

        log.info(
            "published incident",
            extra={
                "incident_id": incident.incident_id,
                "reason": incident.reason,
                "namespace": incident.namespace,
                "pod": incident.pod_name,
            },
        )


class PublishError(RuntimeError):
    """Raised when EventBridge rejects one or more entries."""


def build_publisher(*, dry_run: bool, event_bus_name: str, region: str) -> Publisher:
    """Factory — WATCHER stays decoupled from the concrete impl."""
    if dry_run:
        log.info("using DryRunPublisher (DRY_RUN=true)")
        return DryRunPublisher(event_bus_name=event_bus_name)
    return EventBridgePublisher(event_bus_name=event_bus_name, region=region)
