"""Tests for remediator.bus — RemediationRequested event emission."""

from __future__ import annotations

import json

from remediator import bus
from tests.conftest import BUS_NAME


def _row() -> dict:
    return {
        "namespace":     "demo",
        "podName":       "app-x-6b8c-yyy",
        "containerName": "c",
        "reason":        "OOMKilled",
    }


def test_build_detail_shape() -> None:
    detail = bus.build_detail(
        incident_id="inc-9",
        reason="OOMKilled",
        actor="U0DEV",
        incident_row=_row(),
        now_iso="2026-08-25T10:00:00Z",
    )
    assert detail["schemaVersion"] == "1.0"
    assert detail["incidentId"] == "inc-9"
    assert detail["reason"] == "OOMKilled"
    assert detail["requestedBy"] == "U0DEV"
    assert detail["requestedAt"] == "2026-08-25T10:00:00Z"
    assert detail["namespace"] == "demo"
    assert detail["podName"] == "app-x-6b8c-yyy"
    assert detail["containerName"] == "c"


def test_request_remediation_happy_path(aws_mocks) -> None:
    ok = bus.request_remediation(
        incident_id="inc-9",
        reason="OOMKilled",
        actor="U0DEV",
        incident_row=_row(),
        event_bus_name=BUS_NAME,
        events_client=aws_mocks["events"],
    )
    assert ok is True


def test_request_remediation_soft_fail_on_bad_bus(aws_mocks) -> None:
    """A non-existent bus name is a soft-fail — returns False, doesn't raise."""
    ok = bus.request_remediation(
        incident_id="inc-9",
        reason="OOMKilled",
        actor="U0DEV",
        incident_row=_row(),
        event_bus_name="does-not-exist-bus",
        events_client=aws_mocks["events"],
    )
    assert ok is False


def test_source_and_detail_type_are_stable() -> None:
    assert bus.EVENT_SOURCE == "smartops.remediator"
    assert bus.DETAIL_TYPE == "RemediationRequested"
    assert bus.SCHEMA_VERSION == "1.0"


def test_detail_is_json_encodable() -> None:
    """PutEvents requires Detail as a JSON string — round-trip check."""
    d = bus.build_detail(
        incident_id="i", reason="OOMKilled", actor="U0X", incident_row=_row(),
    )
    parsed = json.loads(json.dumps(d))
    assert parsed == d
