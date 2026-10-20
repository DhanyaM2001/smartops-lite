"""Publisher tests — moto CloudWatch."""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from mttr_aggregator.aggregator import Metric
from mttr_aggregator.publisher import BATCH_SIZE, _to_cw_dict, publish


def test_to_cw_dict_shape_without_dimensions() -> None:
    ts = datetime(2026, 8, 26, 12, 0, 0, tzinfo=timezone.utc)
    d = _to_cw_dict(
        Metric(name="IncidentCount", value=5.0, unit="Count", dimensions={}),
        ts,
    )
    assert d["MetricName"] == "IncidentCount"
    assert d["Value"] == 5.0
    assert d["Unit"] == "Count"
    assert d["Timestamp"] == ts
    assert "Dimensions" not in d


def test_to_cw_dict_shape_with_dimensions() -> None:
    d = _to_cw_dict(
        Metric(name="MTTRSeconds", value=42.5, unit="Seconds",
               dimensions={"Reason": "OOMKilled"}),
        datetime.now(timezone.utc),
    )
    assert d["Dimensions"] == [{"Name": "Reason", "Value": "OOMKilled"}]


def test_publish_zero_metrics_is_noop(aws_mocks) -> None:
    n = publish(
        [],
        namespace="SmartOpsTest",
        cloudwatch_client=aws_mocks["cw"],
    )
    assert n == 0


def test_publish_happy_path(aws_mocks) -> None:
    metrics = [
        Metric("IncidentCount", 3.0, "Count", {}),
        Metric("MTTRSeconds", 45.0, "Seconds", {"Reason": "OOMKilled"}),
        Metric("AckRatePercent", 66.6, "Percent", {}),
    ]
    n = publish(
        metrics,
        namespace="SmartOpsTest",
        cloudwatch_client=aws_mocks["cw"],
    )
    assert n == 3

    # Verify via ListMetrics
    listed = aws_mocks["cw"].list_metrics(Namespace="SmartOpsTest")
    names = {m["MetricName"] for m in listed["Metrics"]}
    assert names == {"IncidentCount", "MTTRSeconds", "AckRatePercent"}


def test_publish_batches_when_over_batch_size(aws_mocks) -> None:
    # Force > BATCH_SIZE items so we hit the batching loop.
    many = [
        Metric(f"Metric{i}", float(i), "Count", {}) for i in range(BATCH_SIZE + 5)
    ]
    n = publish(
        many,
        namespace="SmartOpsTest",
        cloudwatch_client=aws_mocks["cw"],
    )
    assert n == BATCH_SIZE + 5


def test_publish_soft_fails_on_client_error(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[int] = []

    class BrokenCW:
        def put_metric_data(self, **kwargs):
            calls.append(1)
            raise RuntimeError("simulated CW outage")

    metrics = [Metric("X", 1.0, "Count", {})]
    n = publish(metrics, namespace="SmartOpsTest", cloudwatch_client=BrokenCW())
    assert n == 0  # nothing published (soft-fail)
    assert calls == [1]  # attempted once
