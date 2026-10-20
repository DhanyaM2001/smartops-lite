"""Runtime configuration — everything is env-var driven.

Loaded once at process start via `Config.from_env()`. Never mutated at
runtime. Kept in a frozen dataclass so mistyped attribute access fails
loud instead of silently returning None.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _parse_csv(raw: str | None) -> list[str]:
    if not raw:
        return []
    return [x.strip() for x in raw.split(",") if x.strip()]


@dataclass(frozen=True, slots=True)
class Config:
    # ---- AWS side ----
    aws_region: str
    event_bus_name: str
    # DRY_RUN=true → log incidents to stdout instead of calling EventBridge.
    # Used by the local kind demo path where we don't have (or don't want to
    # authenticate to) AWS. All other logic paths are exercised identically.
    dry_run: bool

    # ---- K8s side ----
    # Empty list means "watch all namespaces". A non-empty list restricts to
    # those. Useful for scoping down permissions later.
    watch_namespaces: list[str] = field(default_factory=list)
    # Exclude system + our own controller namespace from event storms.
    exclude_namespaces: list[str] = field(
        default_factory=lambda: ["kube-system", "kube-public", "kube-node-lease", "smartops"]
    )

    # ---- Behavior ----
    log_level: str = "INFO"
    # If the K8s watch stream disconnects, wait N seconds before reconnecting.
    reconnect_backoff_seconds: int = 3
    # How many (namespace, pod, container, reason) tuples to remember before
    # forgetting the oldest — prevents dedup set from growing unbounded on
    # long-running controllers.
    dedup_cache_size: int = 4096

    # ---- Health endpoint ----
    health_port: int = 8081

    # ---- Pod identity (from downward API) ----
    pod_namespace: str = "smartops"
    node_name: str = "unknown"

    @classmethod
    def from_env(cls) -> Config:
        return cls(
            aws_region=os.environ.get("AWS_REGION", "ap-south-1"),
            event_bus_name=os.environ.get("EVENT_BUS_NAME", "smartops-dev"),
            dry_run=os.environ.get("DRY_RUN", "false").lower() in ("1", "true", "yes"),
            watch_namespaces=_parse_csv(os.environ.get("WATCH_NAMESPACES")),
            exclude_namespaces=_parse_csv(os.environ.get("EXCLUDE_NAMESPACES"))
            or ["kube-system", "kube-public", "kube-node-lease", "smartops"],
            log_level=os.environ.get("LOG_LEVEL", "INFO").upper(),
            reconnect_backoff_seconds=int(os.environ.get("RECONNECT_BACKOFF_SECONDS", "3")),
            dedup_cache_size=int(os.environ.get("DEDUP_CACHE_SIZE", "4096")),
            health_port=int(os.environ.get("HEALTH_PORT", "8081")),
            pod_namespace=os.environ.get("POD_NAMESPACE", "smartops"),
            node_name=os.environ.get("NODE_NAME", "unknown"),
        )
