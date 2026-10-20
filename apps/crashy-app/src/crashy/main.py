"""FastAPI app for crashy-app.

Endpoints:
  GET /            — root; returns app identity + hostname
  GET /healthz     — liveness probe (always 200 unless deliberately unhealthy)
  GET /ready       — readiness probe (200 after startup grace)
  GET /crash       — logs then sys.exit(1) → CrashLoopBackOff
  GET /oom         — allocates until OOMKilled (bounded to 200 MiB)
  GET /500         — HTTPException(500) → recorded application error
  GET /slow?ms=N   — sleeps N milliseconds → latency injection

Design notes:
  - The failure endpoints are gated behind /crash, /oom, etc. — never
    triggered by health probes so the pod stays healthy until something
    (or someone) explicitly asks it to break.
  - Every response includes X-Pod-Name / X-Pod-Node headers so a k6/curl
    caller can tell which replica handled which request — useful when
    verifying pod anti-affinity in Module 3 tests.
"""

from __future__ import annotations

import asyncio
import logging
import os
import socket
import sys
import time
from typing import Any

from fastapi import FastAPI, HTTPException, Query, Response
from pydantic import BaseModel

from crashy import __version__

logger = logging.getLogger("crashy")
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)

STARTUP_TS = time.time()
READY_AFTER_SECONDS = float(os.getenv("READY_AFTER_SECONDS", "3"))
POD_NAME = os.getenv("POD_NAME", socket.gethostname())
POD_NODE = os.getenv("POD_NODE", "unknown")
POD_ZONE = os.getenv("POD_ZONE", "unknown")

app = FastAPI(
    title="crashy-app",
    version=__version__,
    description="Deliberately-failing microservice for SmartOps-Lite E2E testing.",
)


class RootResponse(BaseModel):
    """Payload returned by GET /."""

    app: str
    version: str
    pod: str
    node: str
    zone: str
    uptime_seconds: float


@app.middleware("http")
async def add_pod_headers(request: Any, call_next: Any) -> Response:
    """Attach X-Pod-* headers so the caller can see which replica served it."""
    response: Response = await call_next(request)
    response.headers["X-Pod-Name"] = POD_NAME
    response.headers["X-Pod-Node"] = POD_NODE
    response.headers["X-Pod-Zone"] = POD_ZONE
    return response


@app.get("/", response_model=RootResponse)
async def root() -> RootResponse:
    return RootResponse(
        app="crashy-app",
        version=__version__,
        pod=POD_NAME,
        node=POD_NODE,
        zone=POD_ZONE,
        uptime_seconds=round(time.time() - STARTUP_TS, 2),
    )


@app.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness — kubelet restarts the pod if this ever fails."""
    return {"status": "ok"}


@app.get("/ready")
async def ready() -> dict[str, Any]:
    """Readiness — kubelet takes the pod out of the Service until this returns 200."""
    uptime = time.time() - STARTUP_TS
    if uptime < READY_AFTER_SECONDS:
        raise HTTPException(status_code=503, detail=f"warming up ({uptime:.1f}s)")
    return {"status": "ready", "uptime_seconds": round(uptime, 2)}


@app.get("/crash")
async def crash() -> None:
    """Log a scary message and terminate the process with exit code 1.

    The kubelet will restart the container; repeated hits cause CrashLoopBackOff,
    which is exactly the signature Module 4's controller detects.
    """
    logger.error("crashy-app: /crash invoked — exiting with code 1 to trigger CrashLoopBackOff")
    sys.stdout.flush()
    sys.stderr.flush()
    # os._exit skips atexit handlers — matches a real segfault-style abort.
    os._exit(1)  # noqa: SLF001


@app.get("/oom")
async def oom() -> None:
    """Allocate memory until the process is OOMKilled (or we hit 200 MiB, whichever first).

    K8s memory limit for this container is 128 MiB, so we WILL be OOMKilled well
    before the 200 MiB safety cap.
    """
    logger.warning("crashy-app: /oom invoked — allocating memory until OOMKilled")
    hog: list[bytes] = []
    max_bytes = 200 * 1024 * 1024
    chunk = b"x" * (1024 * 1024)  # 1 MiB
    while sum(len(c) for c in hog) < max_bytes:
        hog.append(chunk)
        await asyncio.sleep(0.01)  # yield so probes still respond briefly
    # If we ever get here (limit removed), free memory and return.
    del hog
    return None


@app.get("/500")
async def error500() -> None:
    """Raise a 500-class exception — represents an app-level bug (bad SQL, KeyError, etc.)."""
    logger.error("crashy-app: /500 invoked — raising HTTPException(500)")
    raise HTTPException(status_code=500, detail="deliberate internal error")


@app.get("/slow")
async def slow(
    ms: int = Query(default=5000, ge=0, le=60_000, description="milliseconds to sleep"),
) -> dict[str, int]:
    """Sleep for `ms` milliseconds — simulate a slow downstream dependency."""
    logger.info("crashy-app: /slow invoked, sleeping %d ms", ms)
    await asyncio.sleep(ms / 1000)
    return {"slept_ms": ms}
