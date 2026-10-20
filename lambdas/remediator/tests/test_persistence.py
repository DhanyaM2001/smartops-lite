"""Tests for remediator.persistence — DDB conditional UpdateItem for ack."""

from __future__ import annotations

import pytest

from remediator.persistence import (
    AlreadyAcknowledged,
    acknowledge,
    build_update_kwargs,
)
from tests.conftest import TABLE_NAME, seed_incident


def test_build_update_kwargs_shape() -> None:
    kw = build_update_kwargs(
        incident_id="inc-1",
        actor="U0X",
        now_iso="2026-08-25T00:00:00Z",
    )
    assert kw["Key"] == {"incidentId": {"S": "inc-1"}}
    assert "rcaStatus = :ack" in kw["UpdateExpression"]
    assert "acknowledgedBy = :who" in kw["UpdateExpression"]
    assert "acknowledgedAt = :when" in kw["UpdateExpression"]
    assert kw["ExpressionAttributeValues"][":ack"] == {"S": "acknowledged"}
    assert kw["ExpressionAttributeValues"][":who"] == {"S": "U0X"}
    assert kw["ExpressionAttributeValues"][":when"] == {"S": "2026-08-25T00:00:00Z"}
    assert kw["ReturnValues"] == "ALL_NEW"
    assert "attribute_exists(incidentId)" in kw["ConditionExpression"]


def test_first_ack_succeeds(aws_mocks) -> None:
    seed_incident(aws_mocks["ddb"], incident_id="inc-1")
    row = acknowledge(
        incident_id="inc-1",
        actor="U0DEV",
        table_name=TABLE_NAME,
        ddb_client=aws_mocks["ddb"],
        now_iso="2026-08-25T10:00:00Z",
    )
    assert row["rcaStatus"] == "acknowledged"
    assert row["acknowledgedBy"] == "U0DEV"
    assert row["acknowledgedAt"] == "2026-08-25T10:00:00Z"
    assert row["reason"] == "CrashLoopBackOff"


def test_second_ack_raises_already_acknowledged_with_prior(aws_mocks) -> None:
    seed_incident(aws_mocks["ddb"], incident_id="inc-2")
    acknowledge(
        incident_id="inc-2", actor="U0FIRST",
        table_name=TABLE_NAME, ddb_client=aws_mocks["ddb"],
        now_iso="2026-08-25T10:00:00Z",
    )
    with pytest.raises(AlreadyAcknowledged) as excinfo:
        acknowledge(
            incident_id="inc-2", actor="U0SECOND",
            table_name=TABLE_NAME, ddb_client=aws_mocks["ddb"],
            now_iso="2026-08-25T10:05:00Z",
        )
    assert excinfo.value.actor == "U0FIRST"
    assert excinfo.value.when == "2026-08-25T10:00:00Z"


def test_ack_missing_incident_raises_ccf(aws_mocks) -> None:
    """No row → ConditionalCheckFailed. AlreadyAcknowledged NOT raised (no prior)."""
    with pytest.raises(
        aws_mocks["ddb"].exceptions.ConditionalCheckFailedException
    ):
        acknowledge(
            incident_id="never-existed", actor="U0X",
            table_name=TABLE_NAME, ddb_client=aws_mocks["ddb"],
        )


def test_ack_updates_row_atomically(aws_mocks) -> None:
    """After ack, get_item returns updated fields — full round trip."""
    seed_incident(aws_mocks["ddb"], incident_id="inc-3")
    acknowledge(
        incident_id="inc-3", actor="U0MID",
        table_name=TABLE_NAME, ddb_client=aws_mocks["ddb"],
        now_iso="2026-08-25T11:00:00Z",
    )
    got = aws_mocks["ddb"].get_item(
        TableName=TABLE_NAME, Key={"incidentId": {"S": "inc-3"}}
    )["Item"]
    assert got["rcaStatus"]["S"] == "acknowledged"
    assert got["acknowledgedBy"]["S"] == "U0MID"
    assert got["acknowledgedAt"]["S"] == "2026-08-25T11:00:00Z"
    # Original fields still there
    assert got["reason"]["S"] == "CrashLoopBackOff"
    assert got["podName"]["S"] == "app-x-6b8c-yyy"
