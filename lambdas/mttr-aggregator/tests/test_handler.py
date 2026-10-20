"""End-to-end tests for the Lambda handler.

Handler consumes an EventBridge scheduled event; we synthesize one with a
deterministic `time` field so row-window comparisons don't drift with real
wall-clock time.
"""

from __future__ import annotations

import pytest

from mttr_aggregator import handler


def _schedule_event(now_iso: str) -> dict:
    """Minimal EventBridge Scheduler event shape — only `time` is used."""
    return {"time": now_iso, "source": "aws.events", "detail-type": "Scheduled Event"}


def test_handler_empty_table_publishes_zero_count(aws_mocks) -> None:
    handler._DDB = aws_mocks["ddb"]
    handler._CW = aws_mocks["cw"]

    result = handler.lambda_handler(_schedule_event("2026-08-26T12:00:00Z"), None)
    assert result["statusCode"] == 200
    assert result["rowsScanned"] == 0
    assert result["metricsComputed"] == 1  # zero-count sentinel
    assert result["metricsPublished"] == 1


def test_handler_end_to_end_with_seeded_rows(aws_mocks, seed_ddb) -> None:
    seed_ddb([
        {"reason": "CrashLoopBackOff", "rca_source": "groq",
         "ingested_minutes_ago": 10, "acked_minutes_ago": 5},
        {"reason": "CrashLoopBackOff", "rca_source": "groq",
         "ingested_minutes_ago": 20, "acked_minutes_ago": 15},
        {"reason": "OOMKilled", "rca_source": "fallback",
         "ingested_minutes_ago": 30, "acked_minutes_ago": None},  # no ack
    ])

    handler._DDB = aws_mocks["ddb"]
    handler._CW = aws_mocks["cw"]

    # `2026-08-26T12:00:00Z` matches the seeded-row anchor in conftest.now_utc,
    # so the 60-min default window catches all three seeded rows.
    result = handler.lambda_handler(_schedule_event("2026-08-26T12:00:00Z"), None)
    assert result["statusCode"] == 200
    assert result["rowsScanned"] == 3

    # Confirm the 5 free-tier-safe metric series landed in CloudWatch.
    listed = aws_mocks["cw"].list_metrics(Namespace="SmartOpsTest")
    names = {m["MetricName"] for m in listed["Metrics"]}
    assert names == {
        "IncidentCount",
        "AckedIncidentCount",
        "AckRatePercent",
        "LLMSuccessRatePercent",
        "MTTRSecondsAvg",
    }

    # And critically: NO metric has dimensions (free-tier rule).
    for m in listed["Metrics"]:
        assert m.get("Dimensions", []) == []


def test_handler_config_missing_required_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("INCIDENTS_TABLE_NAME", raising=False)
    with pytest.raises(RuntimeError, match="INCIDENTS_TABLE_NAME"):
        handler.lambda_handler(_schedule_event("2026-08-26T12:00:00Z"), None)


def test_handler_respects_window_env(aws_mocks, seed_ddb, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("WINDOW_MINUTES", "5")
    seed_ddb([
        {"ingested_minutes_ago": 3, "acked_minutes_ago": 1},    # in 5-min window
        {"ingested_minutes_ago": 55, "acked_minutes_ago": 50},  # outside 5-min window
    ])

    handler._DDB = aws_mocks["ddb"]
    handler._CW = aws_mocks["cw"]

    result = handler.lambda_handler(_schedule_event("2026-08-26T12:00:00Z"), None)
    assert result["rowsScanned"] == 1


def test_handler_falls_back_to_wall_clock_when_no_event_time(aws_mocks) -> None:
    """Empty/malformed event MUST NOT crash — degrade to real now."""
    handler._DDB = aws_mocks["ddb"]
    handler._CW = aws_mocks["cw"]

    # No `time` field at all
    result = handler.lambda_handler({}, None)
    assert result["statusCode"] == 200

    # Malformed `time`
    result = handler.lambda_handler({"time": "not-a-date"}, None)
    assert result["statusCode"] == 200


def test_handler_parses_z_suffix_and_offset(aws_mocks) -> None:
    """Both `…Z` and `…+00:00` schedule times must parse identically."""
    handler._DDB = aws_mocks["ddb"]
    handler._CW = aws_mocks["cw"]

    r_z = handler.lambda_handler(_schedule_event("2026-08-26T12:00:00Z"), None)
    r_off = handler.lambda_handler({"time": "2026-08-26T12:00:00+00:00"}, None)
    assert r_z["statusCode"] == 200
    assert r_off["statusCode"] == 200
