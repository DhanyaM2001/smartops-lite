"""HTTP endpoints for K8s probes + metrics scraping.

Kept tiny — three endpoints:
  GET /healthz  → 200 always while the process is alive
  GET /ready    → 200 once the watcher has connected to the API server
  GET /metrics  → JSON snapshot of the watcher's counters (not Prometheus
                  format — that's Module 9's job; this is just useful
                  cluster-side diagnostics)
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from fastapi import FastAPI, Response

if TYPE_CHECKING:  # pragma: no cover
    from smartops_controller.watcher import PodWatcher


def build_app(watcher: PodWatcher) -> FastAPI:
    app = FastAPI(title="smartops-controller", docs_url=None, redoc_url=None)

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/ready")
    def ready(response: Response) -> dict[str, str]:
        if watcher.is_ready():
            return {"status": "ready"}
        response.status_code = 503
        return {"status": "not-ready"}

    @app.get("/metrics")
    def metrics() -> dict[str, int]:
        return dict(watcher.metrics)

    return app
