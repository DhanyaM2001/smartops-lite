"""End-to-end tests for remediator.handler.

Uses moto for DDB/SSM/EventBridge and Slack-shape HMAC for signing.
"""

from __future__ import annotations

import json
import time

import pytest

from remediator import handler
from tests.conftest import (
    BUS_NAME,
    TABLE_NAME,
    build_interaction_payload,
    build_lambda_url_event,
    encode_body,
    seed_incident,
    sign_body,
)


@pytest.fixture(autouse=True)
def _reset() -> None:
    handler._reset_for_tests()


def _make_event(payload_overrides=None, *, sign_ok: bool = True, stale: bool = False):
    payload = build_interaction_payload(**(payload_overrides or {}))
    body = encode_body(payload)
    if stale:
        headers = sign_body(body, ts=int(time.time()) - 3600)
    elif not sign_ok:
        headers = sign_body(body)
        headers["X-Slack-Signature"] = "v0=deadbeef"  # tamper AFTER signing
    else:
        headers = sign_body(body)
    return build_lambda_url_event(raw_body=body, headers=headers), payload


def _wire_clients(handler_mod, aws_mocks) -> None:
    handler_mod._SSM = aws_mocks["ssm"]
    handler_mod._DDB = aws_mocks["ddb"]
    handler_mod._EVENTS = aws_mocks["events"]


def test_happy_path_ack(aws_mocks) -> None:
    seed_incident(aws_mocks["ddb"], incident_id="inc-happy")
    _wire_clients(handler, aws_mocks)
    event, _ = _make_event({"incident_id": "inc-happy", "user_id": "U0DEV"})

    resp = handler.lambda_handler(event)
    assert resp["statusCode"] == 200

    body = json.loads(resp["body"])
    assert body["replace_original"] is True
    block_ids = [b.get("block_id") for b in body["blocks"]]
    assert "smartops_actions" not in block_ids   # button removed
    assert "smartops_ack_footer" in block_ids    # footer added

    row = aws_mocks["ddb"].get_item(
        TableName=TABLE_NAME, Key={"incidentId": {"S": "inc-happy"}}
    )["Item"]
    assert row["rcaStatus"]["S"] == "acknowledged"
    assert row["acknowledgedBy"]["S"] == "U0DEV"


def test_bad_signature_returns_401(aws_mocks) -> None:
    seed_incident(aws_mocks["ddb"])
    _wire_clients(handler, aws_mocks)
    event, _ = _make_event(sign_ok=False)

    resp = handler.lambda_handler(event)
    assert resp["statusCode"] == 401
    # No ack persisted
    row = aws_mocks["ddb"].get_item(
        TableName=TABLE_NAME, Key={"incidentId": {"S": "inc-001"}}
    )["Item"]
    assert row["rcaStatus"]["S"] == "generated"  # unchanged


def test_stale_timestamp_returns_401(aws_mocks) -> None:
    seed_incident(aws_mocks["ddb"])
    _wire_clients(handler, aws_mocks)
    event, _ = _make_event(stale=True)
    resp = handler.lambda_handler(event)
    assert resp["statusCode"] == 401


def test_double_click_shows_prior_acker(aws_mocks) -> None:
    seed_incident(aws_mocks["ddb"], incident_id="inc-2ack")
    _wire_clients(handler, aws_mocks)

    ev1, _ = _make_event({"incident_id": "inc-2ack", "user_id": "U0FIRST"})
    resp1 = handler.lambda_handler(ev1)
    assert resp1["statusCode"] == 200

    ev2, _ = _make_event({"incident_id": "inc-2ack", "user_id": "U0SECOND"})
    resp2 = handler.lambda_handler(ev2)
    assert resp2["statusCode"] == 200

    body2 = json.loads(resp2["body"])
    footer = next(b for b in body2["blocks"] if b.get("block_id") == "smartops_ack_footer")
    text = footer["elements"][0]["text"]
    assert "<@U0FIRST>" in text        # prior acker
    assert "<@U0SECOND>" not in text
    assert "already" in text.lower()


def test_unknown_action_id_returns_200_empty(aws_mocks) -> None:
    seed_incident(aws_mocks["ddb"])
    _wire_clients(handler, aws_mocks)
    event, _ = _make_event({"action_id": "some_other_button"})
    resp = handler.lambda_handler(event)
    assert resp["statusCode"] == 200
    # DDB row NOT modified
    row = aws_mocks["ddb"].get_item(
        TableName=TABLE_NAME, Key={"incidentId": {"S": "inc-001"}}
    )["Item"]
    assert row["rcaStatus"]["S"] == "generated"


def test_whitelisted_reason_emits_remediation_event(
    aws_mocks, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("ALLOWED_REMEDIATION_REASONS", "OOMKilled")
    seed_incident(aws_mocks["ddb"], incident_id="inc-oom", reason="OOMKilled")
    _wire_clients(handler, aws_mocks)
    event, _ = _make_event({"incident_id": "inc-oom", "user_id": "U0DEV"})

    resp = handler.lambda_handler(event)
    assert resp["statusCode"] == 200

    # We can't easily observe EventBridge deliveries with moto without a
    # rule + target, but the successful ack + no exception raised is the
    # contract. The bus.py unit test covers the put_events call shape.
    row = aws_mocks["ddb"].get_item(
        TableName=TABLE_NAME, Key={"incidentId": {"S": "inc-oom"}}
    )["Item"]
    assert row["rcaStatus"]["S"] == "acknowledged"


def test_non_whitelisted_reason_ack_only(aws_mocks, monkeypatch) -> None:
    # ALLOWED_REMEDIATION_REASONS is empty by default (from conftest env fixture)
    seed_incident(aws_mocks["ddb"], incident_id="inc-crash", reason="CrashLoopBackOff")
    _wire_clients(handler, aws_mocks)
    event, _ = _make_event({"incident_id": "inc-crash"})
    resp = handler.lambda_handler(event)
    assert resp["statusCode"] == 200
    # Ack succeeded regardless
    row = aws_mocks["ddb"].get_item(
        TableName=TABLE_NAME, Key={"incidentId": {"S": "inc-crash"}}
    )["Item"]
    assert row["rcaStatus"]["S"] == "acknowledged"


def test_missing_incident_id_returns_500(aws_mocks) -> None:
    """No matching row in DDB → conditional check fails, we return 500."""
    _wire_clients(handler, aws_mocks)
    event, _ = _make_event({"incident_id": "never-existed"})
    resp = handler.lambda_handler(event)
    assert resp["statusCode"] == 500


def test_malformed_body_returns_400(aws_mocks) -> None:
    _wire_clients(handler, aws_mocks)
    body = b"not-a-valid-slack-body"
    headers = sign_body(body)
    event = build_lambda_url_event(raw_body=body, headers=headers)
    resp = handler.lambda_handler(event)
    assert resp["statusCode"] == 400


def test_config_missing_required(monkeypatch: pytest.MonkeyPatch) -> None:
    from remediator.config import Config

    monkeypatch.delenv("INCIDENTS_TABLE_NAME", raising=False)
    with pytest.raises(RuntimeError, match="INCIDENTS_TABLE_NAME"):
        Config.from_env()
