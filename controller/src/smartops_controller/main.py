"""Process entry point — wires config → publisher → watcher → HTTP.

The watcher runs in a background thread so the FastAPI event loop (for
/healthz + /ready) can serve requests without blocking on K8s I/O.
"""

from __future__ import annotations

import logging
import signal
import sys
import threading

import uvicorn
from pythonjsonlogger import jsonlogger

from smartops_controller.config import Config
from smartops_controller.health import build_app
from smartops_controller.publisher import build_publisher
from smartops_controller.watcher import PodWatcher

log = logging.getLogger("smartops_controller")


def _setup_logging(level: str) -> None:
    """Structured JSON logs — one event per line, downstream-parser friendly."""
    handler = logging.StreamHandler(sys.stdout)
    fmt = jsonlogger.JsonFormatter(
        fmt="%(asctime)s %(levelname)s %(name)s %(message)s",
        rename_fields={"asctime": "ts", "levelname": "level", "name": "logger"},
    )
    handler.setFormatter(fmt)
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)
    # Kubernetes client is chatty — quiet it down.
    logging.getLogger("kubernetes").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)


def main() -> None:
    cfg = Config.from_env()
    _setup_logging(cfg.log_level)

    log.info(
        "starting smartops-controller",
        extra={
            "aws_region": cfg.aws_region,
            "event_bus_name": cfg.event_bus_name,
            "dry_run": cfg.dry_run,
            "watch_namespaces": cfg.watch_namespaces or ["*"],
            "exclude_namespaces": cfg.exclude_namespaces,
            "health_port": cfg.health_port,
        },
    )

    publisher = build_publisher(
        dry_run=cfg.dry_run,
        event_bus_name=cfg.event_bus_name,
        region=cfg.aws_region,
    )

    stop_event = threading.Event()
    watcher = PodWatcher(cfg=cfg, publisher=publisher, stop_event=stop_event)

    app = build_app(watcher)
    # Use uvicorn.Server directly instead of uvicorn.run() so the SIGTERM
    # handler can flip should_exit and both the watcher AND the HTTP server
    # shut down cleanly within the pod's terminationGracePeriodSeconds
    # (30 s default) — otherwise K8s eventually SIGKILLs us.
    server_config = uvicorn.Config(
        app,
        host="0.0.0.0",  # noqa: S104 — bound to a pod, exposed via ClusterIP
        port=cfg.health_port,
        log_config=None,  # keep our JSON handler
        access_log=False,
    )
    server = uvicorn.Server(server_config)

    def _shutdown(signum: int, _frame: object) -> None:
        log.info("received signal %d — shutting down", signum)
        stop_event.set()
        server.should_exit = True

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    watcher_thread = threading.Thread(target=watcher.run, name="pod-watcher", daemon=True)
    watcher_thread.start()

    # Blocks until server.should_exit is True (from _shutdown) or Ctrl-C.
    server.run()

    stop_event.set()
    watcher_thread.join(timeout=5.0)
    log.info("bye")


if __name__ == "__main__":
    main()
