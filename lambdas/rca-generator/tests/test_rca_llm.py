"""Tests for rca_generator.rca_llm — Groq client with urllib stubbed."""

from __future__ import annotations

import json
from typing import Any

import pytest

from rca_generator import rca_llm
from rca_generator.schema import parse_event
from tests.conftest import FakeResp, make_groq_response


def test_build_user_prompt_contains_incident_fields(make_event) -> None:
    incident = parse_event(make_event())
    prompt = rca_llm.build_user_prompt(incident)
    assert "CrashLoopBackOff" in prompt
    assert incident.namespace in prompt
    assert incident.pod_name in prompt
    assert incident.container_name in prompt
    assert "restart_count:  5" in prompt
    # Only interesting labels are surfaced
    assert "app.kubernetes.io/name" in prompt


def test_generate_rca_happy_path(monkeypatch: pytest.MonkeyPatch, make_event) -> None:
    incident = parse_event(make_event())
    captured: dict[str, Any] = {}

    def fake_urlopen(req, timeout):  # noqa: ANN001, ARG001
        captured["url"] = req.full_url
        captured["method"] = req.get_method()
        captured["headers"] = {k.lower(): v for k, v in req.headers.items()}
        captured["body"] = json.loads(req.data.decode("utf-8"))
        return FakeResp(status=200, body=make_groq_response("The container crashed. Restart the pod."))

    monkeypatch.setattr(rca_llm.urllib.request, "urlopen", fake_urlopen)

    out = rca_llm.generate_rca(
        incident, api_key="gsk_test", model="llama-3.3-70b-versatile"
    )
    assert out == "The container crashed. Restart the pod."
    assert captured["method"] == "POST"
    assert captured["url"] == rca_llm.GROQ_URL
    assert captured["headers"]["authorization"] == "Bearer gsk_test"
    assert captured["headers"]["content-type"] == "application/json"
    assert captured["body"]["model"] == "llama-3.3-70b-versatile"
    assert captured["body"]["max_tokens"] == 200
    assert isinstance(captured["body"]["messages"], list)
    assert captured["body"]["messages"][0]["role"] == "system"


def test_generate_rca_returns_none_when_no_key(make_event) -> None:
    incident = parse_event(make_event())
    assert rca_llm.generate_rca(incident, api_key=None, model="m") is None
    assert rca_llm.generate_rca(incident, api_key="", model="m") is None


def test_generate_rca_fail_soft_on_urlerror(
    monkeypatch: pytest.MonkeyPatch, make_event
) -> None:
    incident = parse_event(make_event())

    def raising(req, timeout):  # noqa: ANN001, ARG001
        raise rca_llm.urllib.error.URLError("connection refused")

    monkeypatch.setattr(rca_llm.urllib.request, "urlopen", raising)
    assert rca_llm.generate_rca(incident, api_key="k", model="m") is None


def test_generate_rca_fail_soft_on_timeout(
    monkeypatch: pytest.MonkeyPatch, make_event
) -> None:
    incident = parse_event(make_event())

    def slow(req, timeout):  # noqa: ANN001, ARG001
        raise TimeoutError("timed out")

    monkeypatch.setattr(rca_llm.urllib.request, "urlopen", slow)
    assert rca_llm.generate_rca(incident, api_key="k", model="m") is None


def test_generate_rca_fail_soft_on_non_2xx(
    monkeypatch: pytest.MonkeyPatch, make_event
) -> None:
    incident = parse_event(make_event())
    monkeypatch.setattr(
        rca_llm.urllib.request, "urlopen",
        lambda req, timeout: FakeResp(status=500, body='{"error":"boom"}'),
    )
    assert rca_llm.generate_rca(incident, api_key="k", model="m") is None


def test_generate_rca_fail_soft_on_malformed_json(
    monkeypatch: pytest.MonkeyPatch, make_event
) -> None:
    incident = parse_event(make_event())
    monkeypatch.setattr(
        rca_llm.urllib.request, "urlopen",
        lambda req, timeout: FakeResp(status=200, body="this is not JSON"),
    )
    assert rca_llm.generate_rca(incident, api_key="k", model="m") is None


def test_generate_rca_fail_soft_on_missing_choices(
    monkeypatch: pytest.MonkeyPatch, make_event
) -> None:
    incident = parse_event(make_event())
    monkeypatch.setattr(
        rca_llm.urllib.request, "urlopen",
        lambda req, timeout: FakeResp(status=200, body='{"id":"x"}'),
    )
    assert rca_llm.generate_rca(incident, api_key="k", model="m") is None


def test_generate_rca_fail_soft_on_empty_content(
    monkeypatch: pytest.MonkeyPatch, make_event
) -> None:
    incident = parse_event(make_event())
    monkeypatch.setattr(
        rca_llm.urllib.request, "urlopen",
        lambda req, timeout: FakeResp(status=200, body=make_groq_response("   ")),
    )
    assert rca_llm.generate_rca(incident, api_key="k", model="m") is None
