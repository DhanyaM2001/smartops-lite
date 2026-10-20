"""Reusable pytest fixtures for the RCA-generator test suite.

Every fixture is hermetic: no live AWS calls, no network. `moto` mocks
DynamoDB + SSM in-process; Slack and Groq are monkey-patched inside each
test that needs them (see `stub_urlopen` for a batteries-included helper).
"""

from __future__ import annotations

import json
from typing import Any

import boto3
import pytest
from moto import mock_aws


TABLE_NAME = "smartops-incidents-test"
SSM_SLACK_PATH = "/smartops/test/slack_webhook"
SSM_GROQ_PATH = "/smartops/test/groq_api_key"
REGION = "ap-south-1"


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Every test gets deterministic, safe env vars."""
    monkeypatch.setenv("INCIDENTS_TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("SSM_SLACK_WEBHOOK_PATH", SSM_SLACK_PATH)
    monkeypatch.setenv("SSM_GROQ_KEY_PATH", SSM_GROQ_PATH)
    monkeypatch.setenv("SLACK_ENABLED", "true")
    monkeypatch.setenv("SLACK_BLOCKS_ENABLED", "true")
    monkeypatch.setenv("LLM_ENABLED", "true")
    monkeypatch.setenv("LLM_MODEL", "llama-3.3-70b-versatile")
    monkeypatch.setenv("LLM_TIMEOUT_SECONDS", "10")
    monkeypatch.setenv("LLM_MAX_TOKENS", "200")
    monkeypatch.setenv("LOG_LEVEL", "INFO")
    monkeypatch.setenv("SCHEMA_VERSION_EXPECTED", "1.0")
    monkeypatch.setenv("AWS_REGION", REGION)
    # Prevent boto3 from picking up real credentials in a dev laptop.
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")


@pytest.fixture
def aws_mocks():
    """Turn on moto for DDB + SSM. Yields ready-to-use boto3 clients."""
    with mock_aws():
        ddb = boto3.client("dynamodb", region_name=REGION)
        ssm = boto3.client("ssm", region_name=REGION)
        ddb.create_table(
            TableName=TABLE_NAME,
            AttributeDefinitions=[{"AttributeName": "incidentId", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "incidentId", "KeyType": "HASH"}],
            BillingMode="PAY_PER_REQUEST",
        )
        ssm.put_parameter(
            Name=SSM_SLACK_PATH,
            Value="https://hooks.slack.com/services/T00/B00/xxx",
            Type="SecureString",
            Overwrite=True,
        )
        ssm.put_parameter(
            Name=SSM_GROQ_PATH,
            Value="gsk_test_dummy",
            Type="SecureString",
            Overwrite=True,
        )
        yield {"ddb": ddb, "ssm": ssm}


def _make_detail(**overrides: Any) -> dict[str, Any]:
    """Base IncidentDetected detail payload; tests override individual fields."""
    detail: dict[str, Any] = {
        "schemaVersion": "1.0",
        "incidentId": "b48b9a2d-e46c-4c1a-9f26-1d2d78d15f39",
        "namespace": "demo",
        "podName": "app-crashy-app-6b8c-xyz",
        "podUid": "c1e0-dead-beef",
        "containerName": "crashy",
        "reason": "CrashLoopBackOff",
        "restartCount": 5,
        "nodeName": "ip-10-0-1-42",
        "zone": "ap-south-1a",
        "timestamp": "2026-08-24T10:15:32Z",
        "message": "Back-off 5m0s restarting failed container",
        "exitCode": None,
        "labels": {"app.kubernetes.io/name": "crashy-app"},
    }
    detail.update(overrides)
    return detail


@pytest.fixture
def make_event():
    """Factory: returns a full EventBridge envelope with the given detail overrides."""
    def _factory(**detail_overrides: Any) -> dict[str, Any]:
        return {
            "version": "0",
            "id": "d0000000-0000-0000-0000-000000000000",
            "detail-type": "IncidentDetected",
            "source": "smartops.controller",
            "account": "123456789012",
            "time": "2026-08-24T10:15:32Z",
            "region": REGION,
            "resources": [],
            "detail": _make_detail(**detail_overrides),
        }
    return _factory


# ---- HTTP stub helpers (used by Slack + Groq tests) ----------------------

class FakeResp:
    """Minimal urllib response stand-in — context-manager compatible."""

    def __init__(self, status: int = 200, body: str = "") -> None:
        self.status = status
        self._body = body.encode("utf-8")

    def __enter__(self) -> "FakeResp":
        return self

    def __exit__(self, *a: Any) -> None:
        return None

    def read(self) -> bytes:
        return self._body


def make_groq_response(rca_text: str = "Test cause. Test action.") -> str:
    """JSON body that mimics Groq's chat-completions response envelope."""
    return json.dumps({
        "id": "chatcmpl-abc",
        "object": "chat.completion",
        "model": "llama-3.3-70b-versatile",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": rca_text},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 100, "completion_tokens": 30, "total_tokens": 130},
    })
