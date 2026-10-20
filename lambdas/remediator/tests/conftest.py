"""Reusable pytest fixtures for the remediator test suite.

Every fixture is hermetic: moto mocks DDB + SSM + EventBridge; Slack HMAC
is computed with a known signing secret via the `sign_body` helper.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import time
import urllib.parse
from typing import Any

import boto3
import pytest
from moto import mock_aws


TABLE_NAME = "smartops-incidents-test"
BUS_NAME = "smartops-test"
SSM_SIGNING_PATH = "/smartops/test/slack_signing_secret"
SIGNING_SECRET = "abcdef0123456789abcdef0123456789"  # 32 hex chars — Slack-shape
REGION = "ap-south-1"


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("INCIDENTS_TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("SSM_SLACK_SIGNING_SECRET_PATH", SSM_SIGNING_PATH)
    monkeypatch.setenv("EVENT_BUS_NAME", BUS_NAME)
    monkeypatch.setenv("ALLOWED_REMEDIATION_REASONS", "")
    monkeypatch.setenv("REPLAY_WINDOW_SECONDS", "300")
    monkeypatch.setenv("LOG_LEVEL", "INFO")
    monkeypatch.setenv("AWS_REGION", REGION)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")


@pytest.fixture
def aws_mocks():
    """moto AWS clients (DDB + SSM + EventBridge) — DDB pre-seeded with 1 incident."""
    with mock_aws():
        ddb = boto3.client("dynamodb", region_name=REGION)
        ssm = boto3.client("ssm", region_name=REGION)
        events = boto3.client("events", region_name=REGION)

        ddb.create_table(
            TableName=TABLE_NAME,
            AttributeDefinitions=[{"AttributeName": "incidentId", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "incidentId", "KeyType": "HASH"}],
            BillingMode="PAY_PER_REQUEST",
        )
        events.create_event_bus(Name=BUS_NAME)
        ssm.put_parameter(
            Name=SSM_SIGNING_PATH,
            Value=SIGNING_SECRET,
            Type="SecureString",
            Overwrite=True,
        )
        yield {"ddb": ddb, "ssm": ssm, "events": events}


def seed_incident(
    ddb_client,
    *,
    incident_id: str = "inc-001",
    reason: str = "CrashLoopBackOff",
    namespace: str = "demo",
    pod_name: str = "app-x-6b8c-yyy",
    container_name: str = "c",
) -> None:
    """Insert a stub RCA row (as Module 6's Lambda would have)."""
    ddb_client.put_item(
        TableName=TABLE_NAME,
        Item={
            "incidentId":    {"S": incident_id},
            "reason":        {"S": reason},
            "namespace":     {"S": namespace},
            "podName":       {"S": pod_name},
            "containerName": {"S": container_name},
            "rcaStatus":     {"S": "generated"},
            "rcaText":       {"S": "The pod crashed. Restart it."},
        },
    )


# ---- Slack payload helpers ----------------------------------------------

def build_interaction_payload(
    *,
    incident_id: str = "inc-001",
    user_id: str = "U0DEVELOPER",
    action_id: str = "smartops_acknowledge",
    original_blocks: list[dict[str, Any]] | None = None,
    original_text: str = "SmartOps incident",
) -> dict[str, Any]:
    """Minimal Slack `block_actions` payload shape."""
    if original_blocks is None:
        original_blocks = [
            {"type": "header", "text": {"type": "plain_text", "text": "hi"}},
            {
                "type": "actions",
                "block_id": "smartops_actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "Acknowledge"},
                        "action_id": "smartops_acknowledge",
                        "value": incident_id,
                    },
                ],
            },
        ]
    return {
        "type": "block_actions",
        "user": {"id": user_id, "name": "dev"},
        "channel": {"id": "C0GENERAL", "name": "smartops"},
        "message": {"text": original_text, "blocks": original_blocks},
        "actions": [
            {
                "action_id": action_id,
                "block_id": "smartops_actions",
                "value": incident_id,
                "type": "button",
            }
        ],
    }


def encode_body(payload: dict[str, Any]) -> bytes:
    """application/x-www-form-urlencoded body Slack actually sends."""
    return f"payload={urllib.parse.quote(json.dumps(payload))}".encode("utf-8")


def sign_body(raw_body: bytes, *, secret: str = SIGNING_SECRET, ts: int | None = None) -> dict[str, str]:
    """Compute the Slack HMAC signature headers for `raw_body`."""
    if ts is None:
        ts = int(time.time())
    basestring = f"v0:{ts}:".encode("utf-8") + raw_body
    sig = "v0=" + hmac.new(secret.encode(), basestring, hashlib.sha256).hexdigest()
    return {
        "X-Slack-Request-Timestamp": str(ts),
        "X-Slack-Signature": sig,
        "Content-Type": "application/x-www-form-urlencoded",
    }


def build_lambda_url_event(
    *,
    raw_body: bytes,
    headers: dict[str, str],
    is_base64: bool = False,
) -> dict[str, Any]:
    """Lambda Function URL invocation event (payload format v2.0)."""
    body = raw_body.decode("utf-8")
    return {
        "version": "2.0",
        "routeKey": "$default",
        "rawPath": "/",
        "rawQueryString": "",
        "headers": headers,
        "requestContext": {"http": {"method": "POST", "path": "/"}},
        "body": body,
        "isBase64Encoded": is_base64,
    }
