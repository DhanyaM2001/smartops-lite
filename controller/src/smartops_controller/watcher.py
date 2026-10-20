"""Kubernetes Pod watcher — the runtime loop.

Uses `kubernetes.watch.Watch().stream(...)` on the core v1 API to receive
add/modify events for pods, hands each pod to `detector.detect()`, and
publishes the resulting incidents through `Publisher.publish()`.

Handles:
  - In-cluster vs local kubeconfig (auto-detected)
  - Resource-version-aware reconnect after "410 Gone" (normal on long runs)
  - Bounded LRU dedup so a hot-looping pod doesn't spam EventBridge
  - Graceful shutdown on SIGTERM (drains the current event, then exits 0)
"""

from __future__ import annotations

import logging
import threading
from collections import OrderedDict
from typing import Any

from kubernetes import client, config, watch
from kubernetes.client.rest import ApiException

from smartops_controller.config import Config
from smartops_controller.detector import Incident, detect
from smartops_controller.publisher import Publisher

log = logging.getLogger(__name__)


class _LRUSet:
    """Tiny LRU set — Python doesn't ship one and the pip alternatives are overkill."""

    def __init__(self, capacity: int) -> None:
        self._cap = capacity
        self._d: OrderedDict[tuple, None] = OrderedDict()

    def contains_or_add(self, key: tuple) -> bool:
        """True if key already present. Otherwise adds it and returns False.

        Kept for backward compatibility. New callers should use the split
        contains() + add() pair so that publish failures can leave the LRU
        untouched (see _handle_event — publish-first, then mark seen).
        """
        if key in self._d:
            self._d.move_to_end(key)
            return True
        self._d[key] = None
        if len(self._d) > self._cap:
            self._d.popitem(last=False)
        return False

    def contains(self, key: tuple) -> bool:
        """Peek: True if key is in the set. Refreshes LRU order on hit."""
        if key in self._d:
            self._d.move_to_end(key)
            return True
        return False

    def add(self, key: tuple) -> None:
        """Mark key as seen. Idempotent."""
        if key in self._d:
            self._d.move_to_end(key)
            return
        self._d[key] = None
        if len(self._d) > self._cap:
            self._d.popitem(last=False)


def _load_kube_client() -> client.CoreV1Api:
    """Try in-cluster config first (ServiceAccount token), then kubeconfig."""
    try:
        config.load_incluster_config()
        log.info("loaded in-cluster kube config")
    except config.ConfigException:
        config.load_kube_config()
        log.info("loaded local kube config (KUBECONFIG)")
    return client.CoreV1Api()


def _should_skip_namespace(ns: str, cfg: Config) -> bool:
    if cfg.watch_namespaces and ns not in cfg.watch_namespaces:
        return True
    if ns in cfg.exclude_namespaces:
        return True
    return False


class PodWatcher:
    """Runs the watch stream until stop_event is set."""

    def __init__(
        self,
        *,
        cfg: Config,
        publisher: Publisher,
        stop_event: threading.Event,
    ) -> None:
        self.cfg = cfg
        self.publisher = publisher
        self.stop_event = stop_event
        self._seen: _LRUSet = _LRUSet(cfg.dedup_cache_size)
        self._api: client.CoreV1Api | None = None
        self._ready = threading.Event()
        # Metrics — read by the /metrics HTTP endpoint.
        self.metrics: dict[str, int] = {
            "events_seen": 0,
            "incidents_published": 0,
            "incidents_deduped": 0,
            "reconnects": 0,
            "publish_errors": 0,
        }

    def is_ready(self) -> bool:
        """True once we've successfully connected to the API server at least once."""
        return self._ready.is_set()

    def run(self) -> None:
        self._api = _load_kube_client()

        while not self.stop_event.is_set():
            try:
                self._stream_once()
            except ApiException as e:
                # 410 Gone = the resource-version we asked for is too old.
                # The Watch() helper handles it internally, but if it bubbles
                # up, reconnect from HEAD.
                log.warning("k8s ApiException in watch: %s (will reconnect)", e)
                self.metrics["reconnects"] += 1
            except Exception as e:  # noqa: BLE001
                # Anything else: log and retry. Don't die — the pod would just
                # get restarted and we'd resume anyway.
                log.exception("unexpected error in watcher loop: %s", e)
                self.metrics["reconnects"] += 1

            if not self.stop_event.is_set():
                self.stop_event.wait(self.cfg.reconnect_backoff_seconds)

        log.info("watcher stopped cleanly")

    def _stream_once(self) -> None:
        """One connection to the watch stream. Returns when the stream closes."""
        assert self._api is not None
        w = watch.Watch()
        # Watch all pods across the cluster. We filter in memory; RBAC still
        # limits us to what the ClusterRole allows.
        kwargs: dict[str, Any] = {"timeout_seconds": 300}
        stream = w.stream(self._api.list_pod_for_all_namespaces, **kwargs)
        try:
            for event in stream:
                self._ready.set()
                self.metrics["events_seen"] += 1
                if self.stop_event.is_set():
                    w.stop()
                    return
                self._handle_event(event)
        finally:
            w.stop()

    def _handle_event(self, event: dict[str, Any]) -> None:
        event_type = event.get("type", "")
        pod = event.get("object")
        if pod is None or event_type not in ("ADDED", "MODIFIED"):
            return

        ns = getattr(pod.metadata, "namespace", None) if pod.metadata else None
        if not ns or _should_skip_namespace(ns, self.cfg):
            return

        incidents = detect(pod)
        for inc in incidents:
            key = inc.dedup_key()
            # PEEK first — do NOT add to the LRU until publish succeeds.
            # Otherwise a transient EventBridge / IAM / network failure would
            # permanently mask the incident (LRU says "seen", so the next
            # detection is skipped, and the incident is never retried until
            # the entry is evicted — silent data loss).
            if self._seen.contains(key):
                self.metrics["incidents_deduped"] += 1
                continue
            try:
                self.publisher.publish(inc)
            except Exception as e:  # noqa: BLE001
                # Leave key OUT of the LRU on failure — the next watch event
                # for the same pod will retry.
                self.metrics["publish_errors"] += 1
                log.error(
                    "failed to publish incident %s: %s",
                    inc.incident_id,
                    e,
                    extra={"incident_id": inc.incident_id, "reason": inc.reason},
                )
                continue
            # Publish succeeded — now mark seen so we don't republish on
            # subsequent MODIFIED events for the same pod state.
            self._seen.add(key)
            self.metrics["incidents_published"] += 1


def _emit_incident_for_tests(inc: Incident) -> dict:  # pragma: no cover — helper for tests
    return inc.to_dict()
