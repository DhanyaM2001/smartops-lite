"""Incident-detection logic — the pure-function core of the controller.

Given a Kubernetes Pod object (from `list_pod_for_all_namespaces` / `watch`),
decide whether it represents an INCIDENT worth publishing to EventBridge,
and if so, build the structured event payload.

Design notes:
  - Pure functions only. No I/O. No K8s client. Trivially unit-testable.
  - Deduplication is done by the WATCHER (which owns the LRU set); the
    detector emits candidates freely.
  - Reasons we care about (in priority order):
      1. containerStatuses[*].state.waiting.reason == CrashLoopBackOff
      2. containerStatuses[*].state.waiting.reason == ImagePullBackOff /
         ErrImagePull / ErrImageNeverPull
      3. containerStatuses[*].lastState.terminated.reason == OOMKilled
      4. status.phase == "Failed"
  - We emit ONE event per (pod, container, reason). Restart counts are
    included but don't spawn new events.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

# Reasons we treat as incidents. Order matters — first match wins per container.
BAD_WAITING_REASONS: tuple[str, ...] = (
    "CrashLoopBackOff",
    "ImagePullBackOff",
    "ErrImagePull",
    "ErrImageNeverPull",
    "CreateContainerConfigError",
    "CreateContainerError",
    "RunContainerError",
)

BAD_TERMINATED_REASONS: tuple[str, ...] = (
    "OOMKilled",
    "Error",  # non-zero exit
)


@dataclass(frozen=True, slots=True)
class Incident:
    """The structured event we publish to EventBridge.

    Fields map 1-to-1 to the `Detail` payload the RCA Lambda (Module 5) will
    consume. Keeping this frozen so accidental mutation between build-time
    and publish-time is impossible.
    """

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
    timestamp: str  # RFC3339 / ISO-8601 UTC
    message: str
    exit_code: int | None = None
    labels: dict[str, str] = field(default_factory=dict)

    def dedup_key(self) -> tuple[str, str, str, str]:
        """(namespace, pod-name, container, reason) — same tuple never publishes twice."""
        return (self.namespace, self.pod_name, self.container_name, self.reason)

    def to_dict(self) -> dict[str, Any]:
        """Serializable form fed to EventBridge PutEvents' Detail field."""
        return {
            "schemaVersion": self.schema_version,
            "incidentId": self.incident_id,
            "namespace": self.namespace,
            "podName": self.pod_name,
            "podUid": self.pod_uid,
            "containerName": self.container_name,
            "reason": self.reason,
            "restartCount": self.restart_count,
            "nodeName": self.node_name,
            "zone": self.zone,
            "timestamp": self.timestamp,
            "message": self.message,
            "exitCode": self.exit_code,
            "labels": self.labels,
        }


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _get(obj: Any, *path: str, default: Any = None) -> Any:
    """Best-effort nested attribute/key lookup — the K8s python client mixes
    both styles depending on whether you're holding a model or a raw dict.
    """
    cur = obj
    for step in path:
        if cur is None:
            return default
        if isinstance(cur, dict):
            cur = cur.get(step)
        else:
            cur = getattr(cur, step, None)
    return cur if cur is not None else default


def detect(pod: Any, *, schema_version: str = "1.0") -> list[Incident]:
    """Extract zero or more incidents from a Pod object.

    Called on every ADDED/MODIFIED watch event. Returns [] when nothing's
    wrong — that's the normal case for 99% of events.
    """
    incidents: list[Incident] = []

    namespace = _get(pod, "metadata", "namespace", default="unknown")
    pod_name = _get(pod, "metadata", "name", default="unknown")
    pod_uid = _get(pod, "metadata", "uid", default="")
    node_name = _get(pod, "spec", "node_name", default="unknown")

    # Pod labels (may include our anti-affinity zone label, but see below).
    raw_labels = _get(pod, "metadata", "labels", default={}) or {}
    labels: dict[str, str] = {str(k): str(v) for k, v in raw_labels.items()}

    # Zone: propagated from the NODE, not the pod. Cheapest reliable path is
    # the pod label `topology.kubernetes.io/zone` if the workload sets it via
    # downward API; else nil (Module 5 can enrich from the Node object).
    zone: str | None = labels.get("topology.kubernetes.io/zone")

    # ---- Phase-level failures (whole pod dead) --------------------------
    phase = _get(pod, "status", "phase", default="")
    if phase == "Failed":
        incidents.append(
            Incident(
                incident_id=str(uuid.uuid4()),
                schema_version=schema_version,
                namespace=namespace,
                pod_name=pod_name,
                pod_uid=pod_uid,
                container_name="<pod>",
                reason="PodFailed",
                restart_count=0,
                node_name=node_name,
                zone=zone,
                timestamp=_now_iso(),
                message=_get(pod, "status", "message", default="Pod phase=Failed"),
                labels=labels,
            )
        )

    # ---- Per-container failures ----------------------------------------
    container_statuses = _get(pod, "status", "container_statuses", default=[]) or []
    for cs in container_statuses:
        cname = _get(cs, "name", default="unknown")
        restart_count = int(_get(cs, "restart_count", default=0) or 0)

        # Peek at both waiting reason AND last termination reason. Kubernetes
        # will typically show `waiting: CrashLoopBackOff` while the previous
        # container instance actually died of `OOMKilled` / `Error` — if we
        # naively reported the waiting reason, an `/oom` chaos demo would
        # surface as "CrashLoopBackOff" and lose the root cause. Rule:
        # a specific terminated reason (OOMKilled, non-zero-exit Error) beats
        # the generic CrashLoopBackOff loop reason.
        waiting_reason = _get(cs, "state", "waiting", "reason", default="")
        last_terminated_reason = _get(cs, "last_state", "terminated", "reason", default="")
        exit_code = _get(cs, "last_state", "terminated", "exit_code", default=None)
        specific_terminated = (
            last_terminated_reason in BAD_TERMINATED_REASONS
            and not (last_terminated_reason == "Error" and exit_code == 0)
        )

        if waiting_reason == "CrashLoopBackOff" and specific_terminated:
            # Report the more specific terminated reason instead of the loop.
            message = _get(
                cs, "last_state", "terminated", "message", default=last_terminated_reason
            )
            incidents.append(
                Incident(
                    incident_id=str(uuid.uuid4()),
                    schema_version=schema_version,
                    namespace=namespace,
                    pod_name=pod_name,
                    pod_uid=pod_uid,
                    container_name=cname,
                    reason=last_terminated_reason,
                    restart_count=restart_count,
                    node_name=node_name,
                    zone=zone,
                    timestamp=_now_iso(),
                    message=message,
                    exit_code=exit_code,
                    labels=labels,
                )
            )
            continue

        # Currently waiting with a bad reason (not CrashLoopBackOff-with-OOM)?
        if waiting_reason in BAD_WAITING_REASONS:
            message = _get(cs, "state", "waiting", "message", default=waiting_reason)
            incidents.append(
                Incident(
                    incident_id=str(uuid.uuid4()),
                    schema_version=schema_version,
                    namespace=namespace,
                    pod_name=pod_name,
                    pod_uid=pod_uid,
                    container_name=cname,
                    reason=waiting_reason,
                    restart_count=restart_count,
                    node_name=node_name,
                    zone=zone,
                    timestamp=_now_iso(),
                    message=message,
                    labels=labels,
                )
            )
            continue  # don't ALSO report last-state for the same container

        # Last termination showed a bad exit (may or may not still be running).
        if last_terminated_reason in BAD_TERMINATED_REASONS:
            # Exit code 0 with reason "Error" happens on some runtimes — skip.
            if last_terminated_reason == "Error" and exit_code == 0:
                continue
            message = _get(
                cs, "last_state", "terminated", "message", default=last_terminated_reason
            )
            incidents.append(
                Incident(
                    incident_id=str(uuid.uuid4()),
                    schema_version=schema_version,
                    namespace=namespace,
                    pod_name=pod_name,
                    pod_uid=pod_uid,
                    container_name=cname,
                    reason=last_terminated_reason,
                    restart_count=restart_count,
                    node_name=node_name,
                    zone=zone,
                    timestamp=_now_iso(),
                    message=message,
                    exit_code=int(exit_code) if exit_code is not None else None,
                    labels=labels,
                )
            )

    return incidents
