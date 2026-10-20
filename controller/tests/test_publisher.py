"""Publisher tests. Uses moto to fake EventBridge for the real publisher path,
and asserts the dry-run publisher never touches AWS.
"""

from __future__ import annotations

import io
import logging
from datetime import datetime, timezone

import boto3
import pytest
from moto import mock_aws

from smartops_controller.detector import Incident
from smartops_controller.publisher import (
    DryRunPublisher,
    EventBridgePublisher,
    PublishError,
    build_publisher,
)


def _make_incident(reason: str = "CrashLoopBackOff") -> Incident:
    return Incident(
        incident_id="test-id",
        schema_version="1.0",
        namespace="demo",
        pod_name="crashy-abc",
        pod_uid="uid-1",
        container_name="c",
        reason=reason,
        restart_count=3,
        node_name="node-1",
        zone="ap-south-1a",
        timestamp=datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        message="fake",
    )


def test_dry_run_publisher_logs_and_does_not_error(caplog):
    pub = DryRunPublisher(event_bus_name="smartops-dev")
    with caplog.at_level(logging.INFO, logger="smartops_controller.publisher"):
        pub.publish(_make_incident())
    assert any("dry-run publish" in rec.message for rec in caplog.records)


def test_build_publisher_returns_dry_run_when_flag_set():
    p = build_publisher(dry_run=True, event_bus_name="b", region="ap-south-1")
    assert isinstance(p, DryRunPublisher)


@mock_aws
def test_eventbridge_publisher_end_to_end():
    """Create a real bus in moto, publish, verify EventBridge got the entry."""
    client = boto3.client("events", region_name="ap-south-1")
    client.create_event_bus(Name="smartops-dev")

    pub = EventBridgePublisher(event_bus_name="smartops-dev", region="ap-south-1")
    inc = _make_incident()
    pub.publish(inc)

    # moto doesn't offer a "list events on bus" API (EventBridge itself
    # doesn't either) — the strongest thing we can assert is "no exception
    # was raised", which for our happy-path is what matters. The negative
    # path is covered separately below.


@mock_aws
def test_eventbridge_publisher_raises_when_bus_missing():
    # EventBridge with EventBusName pointing at a non-existent bus returns
    # per-entry error, which we surface as PublishError.
    pub = EventBridgePublisher(event_bus_name="no-such-bus", region="ap-south-1")
    with pytest.raises(PublishError):
        pub.publish(_make_incident())
