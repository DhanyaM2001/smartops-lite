"""Shared fixtures — moto DDB + CloudWatch + a `seed_row` helper.

Every fixture is hermetic: no live AWS calls, no network.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

import boto3
import pytest
from moto import mock_aws


TABLE_NAME = "smartops-incidents-test"
REGION = "ap-south-1"
NAMESPACE = "SmartOpsTest"


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Deterministic, safe env vars for every test."""
    monkeypatch.setenv("INCIDENTS_TABLE_NAME", TABLE_NAME)
    monkeypatch.setenv("METRIC_NAMESPACE", NAMESPACE)
    monkeypatch.setenv("WINDOW_MINUTES", "60")
    monkeypatch.setenv("LOG_LEVEL", "INFO")
    monkeypatch.setenv("AWS_REGION", REGION)
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "testing")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "testing")
    monkeypatch.setenv("AWS_SESSION_TOKEN", "testing")


@pytest.fixture(autouse=True)
def _reset_handler_state() -> None:
    from mttr_aggregator import handler
    handler._reset_for_tests()
    yield
    handler._reset_for_tests()


@pytest.fixture
def aws_mocks():
    """moto DDB + CloudWatch, table pre-created."""
    with mock_aws():
        ddb = boto3.client("dynamodb", region_name=REGION)
        cw = boto3.client("cloudwatch", region_name=REGION)
        ddb.create_table(
            TableName=TABLE_NAME,
            AttributeDefinitions=[{"AttributeName": "incidentId", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "incidentId", "KeyType": "HASH"}],
            BillingMode="PAY_PER_REQUEST",
        )
        yield {"ddb": ddb, "cw": cw}


def _iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds").replace("+00:00", "Z")


@pytest.fixture
def now_utc() -> datetime:
    return datetime(2026, 8, 26, 12, 0, 0, tzinfo=timezone.utc)


@pytest.fixture
def make_row(now_utc):
    """Factory for a fully-populated DDB row (already unmarshalled shape)."""
    counter = {"n": 0}

    def _factory(
        *,
        reason: str = "CrashLoopBackOff",
        rca_source: str = "groq",
        ingested_minutes_ago: int = 5,
        acked_minutes_ago: int | None = 2,
        rca_status: str | None = None,
    ) -> dict[str, Any]:
        counter["n"] += 1
        ingested = now_utc - timedelta(minutes=ingested_minutes_ago)
        row: dict[str, Any] = {
            "incidentId": f"inc-{counter['n']:04d}",
            "schemaVersion": "1.0",
            "namespace": "demo",
            "podName": f"crashy-app-abc-{counter['n']:03d}",
            "containerName": "crashy",
            "reason": reason,
            "restartCount": 5,
            "nodeName": "node-1",
            "zone": "ap-south-1a",
            "timestamp": _iso(ingested - timedelta(seconds=10)),
            "message": "Back-off restarting failed container",
            "labels": {"app.kubernetes.io/name": "crashy-app"},
            "ingestedAt": _iso(ingested),
            "rcaText": "Test cause. Test action.",
            "rcaStatus": rca_status or ("acknowledged" if acked_minutes_ago is not None else "generated"),
            "rcaSource": rca_source,
        }
        if acked_minutes_ago is not None:
            acked = now_utc - timedelta(minutes=acked_minutes_ago)
            row["acknowledgedAt"] = _iso(acked)
            row["acknowledgedBy"] = "U0TEST"
        return row

    return _factory


@pytest.fixture
def seed_ddb(aws_mocks, make_row):
    """Helper: write N rows into the moto DDB table.

    Returns the list of rows written (already in unmarshalled dict form).
    """
    def _seed(specs: list[dict[str, Any]]) -> list[dict[str, Any]]:
        # Local marshaller mirrors persistence._marshall.
        rows = [make_row(**s) for s in specs]
        for row in rows:
            item: dict[str, dict[str, Any]] = {}
            for k, v in row.items():
                if v is None:
                    item[k] = {"NULL": True}
                elif isinstance(v, bool):
                    item[k] = {"BOOL": v}
                elif isinstance(v, int):
                    item[k] = {"N": str(v)}
                elif isinstance(v, str):
                    item[k] = {"S": v}
                elif isinstance(v, dict):
                    item[k] = {"M": {sk: {"S": str(sv)} for sk, sv in v.items()}}
                else:
                    item[k] = {"S": str(v)}
            aws_mocks["ddb"].put_item(TableName=TABLE_NAME, Item=item)
        return rows

    return _seed
