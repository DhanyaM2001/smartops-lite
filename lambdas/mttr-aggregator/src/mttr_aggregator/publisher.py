"""CloudWatch PutMetricData publisher.

Handles the API's constraints so callers don't have to:
  - Max 1000 items per PutMetricData call (we batch at 500 to stay well under).
  - Dimensions become empty list when the metric has none — CW client API
    accepts either, but the empty-list form is explicit.
  - Timestamp defaults to "now" if not provided.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

from mttr_aggregator.aggregator import Metric

log = logging.getLogger(__name__)

# CloudWatch caps PutMetricData at 1000 items; we batch at 500 for safety.
BATCH_SIZE = 500


def _to_cw_dict(m: Metric, timestamp: datetime) -> dict[str, Any]:
    d: dict[str, Any] = {
        "MetricName": m.name,
        "Value": m.value,
        "Unit": m.unit,
        "Timestamp": timestamp,
    }
    if m.dimensions:
        d["Dimensions"] = [
            {"Name": k, "Value": v} for k, v in m.dimensions.items()
        ]
    return d


def publish(
    metrics: list[Metric],
    *,
    namespace: str,
    cloudwatch_client,
    timestamp: datetime | None = None,
) -> int:
    """Publish every metric to CloudWatch. Returns count of published items.

    Fail-soft: PutMetricData errors are logged but not raised. The next 5-min
    schedule run will re-emit fresh values — nothing observable to Grafana is
    lost forever.
    """
    if not metrics:
        log.info("no metrics to publish")
        return 0

    ts = timestamp or datetime.now(timezone.utc)
    payload = [_to_cw_dict(m, ts) for m in metrics]
    published = 0

    for i in range(0, len(payload), BATCH_SIZE):
        chunk = payload[i:i + BATCH_SIZE]
        try:
            cloudwatch_client.put_metric_data(
                Namespace=namespace,
                MetricData=chunk,
            )
            published += len(chunk)
        except Exception as e:  # noqa: BLE001 — CW failure is soft
            log.warning(
                "cloudwatch put_metric_data failed (soft)",
                extra={
                    "namespace": namespace,
                    "batch_start": i,
                    "batch_size": len(chunk),
                    "error": str(e),
                },
            )

    log.info(
        "metrics published",
        extra={
            "namespace": namespace,
            "published": published,
            "requested": len(payload),
        },
    )
    return published
