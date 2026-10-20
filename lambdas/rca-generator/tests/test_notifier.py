"""Tests for rca_generator.notifier — Slack HTTP with urllib stubbed."""

from __future__ import annotations

import json
from typing import Any

import pytest

from rca_generator import notifier
from rca_generator.schema import parse_event
from tests.conftest import FakeResp


def test_build_message_shape(make_event) -> None:
    incident = parse_event(make_event())
    msg = notifier.build_message(incident)
    assert "CrashLoopBackOff" in msg
    assert "demo/app-crashy-app-6b8c-xyz" in msg
    assert incident.incident_id in msg


def test_notify_returns_false_when_webhook_missing(make_event) -> None:
    incident = parse_event(make_event())
    assert notifier.notify(incident, webhook_url=None) is False
    assert notifier.notify(incident, webhook_url="") is False


def test_notify_posts_json_body(monkeypatch: pytest.MonkeyPatch, make_event) -> None:
    incident = parse_event(make_event())
    captured: dict[str, Any] = {}

    def fake_urlopen(req, timeout):  # noqa: ANN001, ARG001
        captured["url"] = req.full_url
        captured["method"] = req.get_method()
        captured["headers"] = dict(req.headers)
        captured["body"] = req.data
        return FakeResp(status=200)

    monkeypatch.setattr(notifier.urllib.request, "urlopen", fake_urlopen)

    result = notifier.notify(incident, webhook_url="https://hooks.slack.com/x/y/z")
    assert result is True
    assert captured["method"] == "POST"
    header_names = {k.lower(): v for k, v in captured["headers"].items()}
    assert header_names.get("content-type") == "application/json"
    body = json.loads(captured["body"].decode("utf-8"))
    assert "text" in body
    assert "CrashLoopBackOff" in body["text"]


def test_notify_fail_soft_on_http_error(monkeypatch: pytest.MonkeyPatch, make_event) -> None:
    incident = parse_event(make_event())

    def raising(req, timeout):  # noqa: ANN001, ARG001
        raise notifier.urllib.error.URLError("connection refused")

    monkeypatch.setattr(notifier.urllib.request, "urlopen", raising)
    assert notifier.notify(incident, webhook_url="https://hooks.slack.com/x") is False


def test_notify_fail_soft_on_non_2xx(monkeypatch: pytest.MonkeyPatch, make_event) -> None:
    incident = parse_event(make_event())
    monkeypatch.setattr(
        notifier.urllib.request, "urlopen",
        lambda req, timeout: FakeResp(status=500),
    )
    assert notifier.notify(incident, webhook_url="https://hooks.slack.com/x") is False


# ---- send_payload (Module 6) ---------------------------------------------

def test_send_payload_dispatches_arbitrary_dict(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """send_payload accepts any JSON-serializable dict (Block Kit or plain)."""
    captured: dict[str, Any] = {}

    def fake_urlopen(req, timeout):  # noqa: ANN001, ARG001
        captured["body"] = req.data
        return FakeResp(status=200)

    monkeypatch.setattr(notifier.urllib.request, "urlopen", fake_urlopen)

    block_kit_payload = {"text": "fallback", "attachments": [{"color": "#d0021b"}]}
    ok = notifier.send_payload(
        block_kit_payload,
        webhook_url="https://hooks.slack.com/x",
        incident_id="test-id",
    )
    assert ok is True
    assert json.loads(captured["body"].decode("utf-8")) == block_kit_payload


def test_send_payload_returns_false_when_no_webhook() -> None:
    assert notifier.send_payload({"text": "x"}, webhook_url=None) is False
    assert notifier.send_payload({"text": "x"}, webhook_url="") is False


def test_send_payload_fail_soft_on_network_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def raising(req, timeout):  # noqa: ANN001, ARG001
        raise notifier.urllib.error.URLError("boom")

    monkeypatch.setattr(notifier.urllib.request, "urlopen", raising)
    ok = notifier.send_payload(
        {"text": "x"}, webhook_url="https://hooks.slack.com/x"
    )
    assert ok is False
