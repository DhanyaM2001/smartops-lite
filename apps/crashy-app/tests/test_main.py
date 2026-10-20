"""Smoke tests for crashy-app's non-destructive endpoints.

The destructive endpoints (/crash, /oom) can't run in-process because they
would abort the test worker. Those are covered by the Helm chart's e2e
in Module 3's runbook (curl → observe CrashLoopBackOff / OOMKilled events).
"""

from __future__ import annotations

import time

import pytest
from fastapi.testclient import TestClient

from crashy.main import READY_AFTER_SECONDS, app

client = TestClient(app)


def test_root_returns_identity() -> None:
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.json()
    assert body["app"] == "crashy-app"
    assert body["version"]
    assert "pod" in body and "node" in body and "zone" in body
    assert body["uptime_seconds"] >= 0
    assert resp.headers["X-Pod-Name"]  # middleware attaches it


def test_healthz_always_ok() -> None:
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_ready_warms_up() -> None:
    resp = client.get("/ready")
    if resp.status_code == 503:
        assert "warming up" in resp.json()["detail"]
        time.sleep(READY_AFTER_SECONDS + 0.5)
        resp = client.get("/ready")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ready"


def test_500_raises() -> None:
    resp = client.get("/500")
    assert resp.status_code == 500
    assert "deliberate" in resp.json()["detail"]


@pytest.mark.parametrize("ms", [0, 50, 200])
def test_slow_sleeps(ms: int) -> None:
    t0 = time.perf_counter()
    resp = client.get(f"/slow?ms={ms}")
    elapsed_ms = (time.perf_counter() - t0) * 1000
    assert resp.status_code == 200
    assert resp.json() == {"slept_ms": ms}
    # tolerate scheduler jitter but confirm we actually slept
    assert elapsed_ms >= ms - 5, f"slept {elapsed_ms:.0f}ms, requested {ms}ms"


def test_slow_rejects_out_of_range() -> None:
    resp = client.get("/slow?ms=999999")
    assert resp.status_code == 422  # pydantic validation
