"""End-to-end tests for handler.lambda_handler (Module 5.0 + Module 6).

Uses moto for DDB + SSM and monkey-patches urllib for Slack + Groq.
"""

from __future__ import annotations

import json
from typing import Any

import pytest

from rca_generator import handler, notifier, rca_llm
from rca_generator.schema import SchemaError
from tests.conftest import TABLE_NAME, FakeResp, make_groq_response


@pytest.fixture(autouse=True)
def _reset_handler_state() -> None:
    handler._reset_for_tests()


def _install_stubs(
    monkeypatch: pytest.MonkeyPatch,
    *,
    groq_status: int = 200,
    groq_body: str | None = None,
    groq_raises: BaseException | None = None,
    slack_status: int = 200,
    slack_raises: BaseException | None = None,
    slack_captures: list[bytes] | None = None,
) -> None:
    """Patch urllib.request.urlopen with a URL-dispatching stub.

    NOTE: `rca_llm.urllib.request` and `notifier.urllib.request` reference the
    SAME `urllib.request` module. If we monkeypatch both separately, the
    second setattr silently overrides the first — so Groq and Slack ended up
    sharing one stub. We use a URL-dispatch pattern so the stub knows which
    endpoint it's being called for.
    """
    if groq_body is None:
        groq_body = make_groq_response("The container crashed. Restart the pod.")

    def dispatched_urlopen(req, timeout):  # noqa: ANN001, ARG001
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "groq.com" in url:
            if groq_raises:
                raise groq_raises
            return FakeResp(status=groq_status, body=groq_body)
        # Any other URL is treated as Slack (hooks.slack.com in prod).
        if slack_raises:
            raise slack_raises
        if slack_captures is not None:
            slack_captures.append(req.data)
        return FakeResp(status=slack_status)

    # Patch once on the shared module — both rca_llm and notifier see it.
    monkeypatch.setattr(rca_llm.urllib.request, "urlopen", dispatched_urlopen)


def test_end_to_end_happy_path_with_llm(
    aws_mocks, make_event, monkeypatch: pytest.MonkeyPatch
) -> None:
    slack_bodies: list[bytes] = []
    _install_stubs(monkeypatch, slack_captures=slack_bodies)

    handler._SSM = aws_mocks["ssm"]
    handler._DDB = aws_mocks["ddb"]

    resp = handler.lambda_handler(make_event())

    assert resp["statusCode"] == 200
    assert resp["persisted"] is True
    assert resp["rcaStatus"] == "generated"
    assert resp["rcaSource"] == "groq"
    assert resp["slackSent"] is True

    # DDB row contains LLM output, not the placeholder
    row = aws_mocks["ddb"].get_item(
        TableName=TABLE_NAME,
        Key={"incidentId": {"S": resp["incidentId"]}},
    )
    item = row["Item"]
    assert item["rcaStatus"]["S"] == "generated"
    assert item["rcaSource"]["S"] == "groq"
    assert "container crashed" in item["rcaText"]["S"]

    # Slack payload is Block Kit
    assert len(slack_bodies) == 1
    slack_payload = json.loads(slack_bodies[0].decode("utf-8"))
    assert "attachments" in slack_payload
    assert slack_payload["attachments"][0]["color"] == "#d0021b"  # red for CrashLoopBackOff


def test_llm_failure_falls_back_to_placeholder(
    aws_mocks, make_event, monkeypatch: pytest.MonkeyPatch
) -> None:
    slack_bodies: list[bytes] = []
    _install_stubs(
        monkeypatch,
        groq_raises=rca_llm.urllib.error.URLError("groq unreachable"),
        slack_captures=slack_bodies,
    )

    handler._SSM = aws_mocks["ssm"]
    handler._DDB = aws_mocks["ddb"]

    resp = handler.lambda_handler(make_event())

    assert resp["persisted"] is True
    assert resp["rcaStatus"] == "pending"
    assert resp["rcaSource"] == "fallback"
    assert resp["slackSent"] is True

    # DDB still written (with placeholder), Slack still sent (with fallback label)
    row = aws_mocks["ddb"].get_item(
        TableName=TABLE_NAME, Key={"incidentId": {"S": resp["incidentId"]}}
    )
    item = row["Item"]
    assert item["rcaStatus"]["S"] == "pending"
    assert item["rcaSource"]["S"] == "fallback"
    # Slack card should have the fallback label
    slack_payload = json.loads(slack_bodies[0].decode("utf-8"))
    rca_block_text = next(
        b["text"]["text"] for b in slack_payload["attachments"][0]["blocks"]
        if b["type"] == "section" and "*RCA" in b.get("text", {}).get("text", "")
    )
    assert "*RCA (fallback)*" in rca_block_text


def test_llm_disabled_via_env_skips_groq(
    aws_mocks, make_event, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("LLM_ENABLED", "false")

    groq_calls: list[Any] = []

    def dispatched(req, timeout):  # noqa: ANN001, ARG001
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "groq.com" in url:
            groq_calls.append(req)
            return FakeResp(status=200, body=make_groq_response("nope"))
        return FakeResp(status=200)

    monkeypatch.setattr(rca_llm.urllib.request, "urlopen", dispatched)

    handler._SSM = aws_mocks["ssm"]
    handler._DDB = aws_mocks["ddb"]

    resp = handler.lambda_handler(make_event())
    assert resp["persisted"] is True
    assert resp["rcaStatus"] == "pending"
    assert resp["rcaSource"] == "none"
    assert groq_calls == []  # Groq not called at all


def test_slack_blocks_disabled_uses_plaintext(
    aws_mocks, make_event, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SLACK_BLOCKS_ENABLED", "false")

    slack_bodies: list[bytes] = []
    _install_stubs(monkeypatch, slack_captures=slack_bodies)

    handler._SSM = aws_mocks["ssm"]
    handler._DDB = aws_mocks["ddb"]

    resp = handler.lambda_handler(make_event())
    assert resp["slackSent"] is True
    payload = json.loads(slack_bodies[0].decode("utf-8"))
    # Plain-text payload has "text" but no "attachments"/"blocks"
    assert "text" in payload
    assert "attachments" not in payload


def test_slack_disabled_still_persists(
    aws_mocks, make_event, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("SLACK_ENABLED", "false")

    slack_calls: list[Any] = []

    def dispatched(req, timeout):  # noqa: ANN001, ARG001
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "groq.com" in url:
            return FakeResp(status=200, body=make_groq_response())
        slack_calls.append(1)
        return FakeResp()

    monkeypatch.setattr(rca_llm.urllib.request, "urlopen", dispatched)

    handler._SSM = aws_mocks["ssm"]
    handler._DDB = aws_mocks["ddb"]

    resp = handler.lambda_handler(make_event())
    assert resp["persisted"] is True
    assert resp["slackSent"] is False
    assert slack_calls == []


def test_slack_failure_does_not_block_persist(
    aws_mocks, make_event, monkeypatch: pytest.MonkeyPatch
) -> None:
    _install_stubs(
        monkeypatch,
        slack_raises=notifier.urllib.error.URLError("slack down"),
    )

    handler._SSM = aws_mocks["ssm"]
    handler._DDB = aws_mocks["ddb"]

    resp = handler.lambda_handler(make_event())
    assert resp["persisted"] is True
    assert resp["slackSent"] is False  # fail-soft

    row = aws_mocks["ddb"].get_item(
        TableName=TABLE_NAME, Key={"incidentId": {"S": resp["incidentId"]}}
    )
    assert row.get("Item") is not None


def test_schema_error_raises_before_llm_or_ddb(
    aws_mocks, make_event, monkeypatch: pytest.MonkeyPatch
) -> None:
    groq_calls: list[Any] = []
    slack_calls: list[Any] = []

    def dispatched(req, timeout):  # noqa: ANN001, ARG001
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "groq.com" in url:
            groq_calls.append(1)
        else:
            slack_calls.append(1)
        return FakeResp()

    monkeypatch.setattr(rca_llm.urllib.request, "urlopen", dispatched)

    handler._SSM = aws_mocks["ssm"]
    handler._DDB = aws_mocks["ddb"]

    bad_event = make_event()
    bad_event["source"] = "aws.other"

    with pytest.raises(SchemaError):
        handler.lambda_handler(bad_event)

    scan = aws_mocks["ddb"].scan(TableName=TABLE_NAME)
    assert scan["Count"] == 0
    assert groq_calls == []  # never even attempted
    assert slack_calls == []


def test_config_loads_module6_env_vars(monkeypatch: pytest.MonkeyPatch) -> None:
    from rca_generator.config import Config

    monkeypatch.setenv("LLM_ENABLED", "false")
    monkeypatch.setenv("LLM_MODEL", "custom-model")
    monkeypatch.setenv("LLM_TIMEOUT_SECONDS", "15")
    monkeypatch.setenv("LLM_MAX_TOKENS", "500")
    monkeypatch.setenv("SLACK_BLOCKS_ENABLED", "false")

    cfg = Config.from_env()
    assert cfg.llm_enabled is False
    assert cfg.llm_model == "custom-model"
    assert cfg.llm_timeout_seconds == 15
    assert cfg.llm_max_tokens == 500
    assert cfg.slack_blocks_enabled is False


def test_config_missing_required(monkeypatch: pytest.MonkeyPatch) -> None:
    from rca_generator.config import Config

    monkeypatch.delenv("INCIDENTS_TABLE_NAME", raising=False)
    with pytest.raises(RuntimeError, match="INCIDENTS_TABLE_NAME"):
        Config.from_env()
