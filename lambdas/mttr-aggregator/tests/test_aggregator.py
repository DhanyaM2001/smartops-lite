"""Pure aggregate() tests — no AWS, no moto.

All metrics are no-dimension in Module 9 (free-tier ceiling = 10 unique
metric series; we emit 5). Per-reason breakouts live in Logs Insights.
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from mttr_aggregator.aggregator import Metric, _parse_iso, aggregate


def _iso(dt: datetime) -> str:
    return dt.isoformat(timespec="seconds").replace("+00:00", "Z")


def _find(metrics: list[Metric], name: str) -> Metric | None:
    for m in metrics:
        if m.name == name:
            return m
    return None


# ------------------------------------------------------------- structural

def test_empty_rows_yields_zero_count_only() -> None:
    metrics = aggregate([])
    assert len(metrics) == 1
    m = metrics[0]
    assert m.name == "IncidentCount"
    assert m.value == 0.0
    assert m.unit == "Count"
    assert m.dimensions == {}


def test_all_metrics_have_no_dimensions() -> None:
    """Free-tier compliance: every emitted metric MUST have empty dims."""
    now = datetime.now(timezone.utc)
    rows = [
        {
            "reason": "CrashLoopBackOff",
            "rcaSource": "groq",
            "ingestedAt": _iso(now - timedelta(seconds=60)),
            "acknowledgedAt": _iso(now),
        },
        {
            "reason": "OOMKilled",
            "rcaSource": "fallback",
            "ingestedAt": _iso(now - timedelta(seconds=200)),
            # no ack
        },
    ]
    metrics = aggregate(rows)
    for m in metrics:
        assert m.dimensions == {}, f"metric {m.name} has dimensions {m.dimensions} — breaks free-tier"


def test_metric_count_is_at_most_five() -> None:
    """We publish AT MOST 5 metric series (10 free-tier ceiling with headroom)."""
    now = datetime.now(timezone.utc)
    rows = [
        {
            "reason": "CrashLoopBackOff",
            "rcaSource": "groq",
            "ingestedAt": _iso(now - timedelta(seconds=30)),
            "acknowledgedAt": _iso(now),
        },
    ]
    metrics = aggregate(rows)
    unique_series = {(m.name, tuple(sorted(m.dimensions.items()))) for m in metrics}
    assert len(unique_series) <= 5


# ------------------------------------------------------------- semantics

def test_single_acked_row_produces_all_five_metrics() -> None:
    now = datetime(2026, 8, 26, 12, 0, 0, tzinfo=timezone.utc)
    row = {
        "reason": "CrashLoopBackOff",
        "rcaSource": "groq",
        "ingestedAt": _iso(now - timedelta(seconds=120)),
        "acknowledgedAt": _iso(now - timedelta(seconds=30)),
    }
    metrics = aggregate([row], now_utc=now)

    inc = _find(metrics, "IncidentCount")
    assert inc and inc.value == 1.0

    acked = _find(metrics, "AckedIncidentCount")
    assert acked and acked.value == 1.0

    mttr = _find(metrics, "MTTRSecondsAvg")
    assert mttr and mttr.value == 90.0  # 120 − 30
    assert mttr.unit == "Seconds"

    ack_pct = _find(metrics, "AckRatePercent")
    assert ack_pct and ack_pct.value == 100.0
    assert ack_pct.unit == "Percent"

    llm_pct = _find(metrics, "LLMSuccessRatePercent")
    assert llm_pct and llm_pct.value == 100.0


def test_ack_rate_when_partial() -> None:
    now = datetime.now(timezone.utc)
    rows = [
        # acked
        {
            "reason": "OOMKilled",
            "rcaSource": "fallback",
            "ingestedAt": _iso(now - timedelta(seconds=200)),
            "acknowledgedAt": _iso(now - timedelta(seconds=100)),
        },
        # unacked
        {
            "reason": "OOMKilled",
            "rcaSource": "groq",
            "ingestedAt": _iso(now - timedelta(seconds=60)),
        },
    ]
    metrics = aggregate(rows, now_utc=now)

    assert _find(metrics, "IncidentCount").value == 2.0
    assert _find(metrics, "AckedIncidentCount").value == 1.0
    assert _find(metrics, "AckRatePercent").value == 50.0
    assert _find(metrics, "MTTRSecondsAvg").value == 100.0  # only the acked row


def test_llm_success_rate_split() -> None:
    """LLMSuccessRatePercent = 100 * (rcaSource==groq) / total."""
    now = datetime.now(timezone.utc)
    rows = [
        {"reason": "X", "rcaSource": "groq", "ingestedAt": _iso(now)},
        {"reason": "X", "rcaSource": "groq", "ingestedAt": _iso(now)},
        {"reason": "X", "rcaSource": "fallback", "ingestedAt": _iso(now)},
        {"reason": "X", "rcaSource": "none", "ingestedAt": _iso(now)},
    ]
    metrics = aggregate(rows)
    assert _find(metrics, "LLMSuccessRatePercent").value == 50.0  # 2 / 4


def test_no_mttr_metric_when_no_row_is_acked() -> None:
    """Skip MTTR if no acknowledged rows — avoid emitting 0-second averages."""
    now = datetime.now(timezone.utc)
    rows = [
        {"reason": "X", "rcaSource": "groq", "ingestedAt": _iso(now)},
        {"reason": "X", "rcaSource": "groq", "ingestedAt": _iso(now)},
    ]
    metrics = aggregate(rows)
    assert _find(metrics, "MTTRSecondsAvg") is None
    # But the other 4 metrics ARE emitted
    assert _find(metrics, "IncidentCount").value == 2.0
    assert _find(metrics, "AckRatePercent").value == 0.0


def test_negative_delta_dropped_from_mttr() -> None:
    """acknowledgedAt BEFORE ingestedAt = clock skew — skip that row's MTTR
    but still count it as an incident."""
    now = datetime.now(timezone.utc)
    good_row = {
        "reason": "X", "rcaSource": "groq",
        "ingestedAt": _iso(now - timedelta(seconds=100)),
        "acknowledgedAt": _iso(now - timedelta(seconds=20)),
    }
    skewed_row = {
        "reason": "X", "rcaSource": "groq",
        "ingestedAt": _iso(now - timedelta(seconds=60)),
        "acknowledgedAt": _iso(now - timedelta(seconds=90)),  # 30s in the past
    }
    metrics = aggregate([good_row, skewed_row])
    # Only 1 valid MTTR contribution → avg == 80
    assert _find(metrics, "MTTRSecondsAvg").value == 80.0
    # But BOTH still count as incidents
    assert _find(metrics, "IncidentCount").value == 2.0
    # Ack count is 1 (the valid one)
    assert _find(metrics, "AckedIncidentCount").value == 1.0


def test_missing_ingested_or_acked_excluded_from_mttr() -> None:
    rows = [
        {"reason": "X", "rcaSource": "groq"},  # no timestamps at all
        {"reason": "X", "rcaSource": "groq", "acknowledgedAt": "2026-01-01T00:00:00Z"},
        {"reason": "X", "rcaSource": "groq", "ingestedAt": "2026-01-01T00:00:00Z"},
    ]
    metrics = aggregate(rows)
    # None had both timestamps → no MTTR metric
    assert _find(metrics, "MTTRSecondsAvg") is None
    # But 3 incidents still counted
    assert _find(metrics, "IncidentCount").value == 3.0


# ------------------------------------------------------------- _parse_iso

@pytest.mark.parametrize(
    "ts,expected_is_none",
    [
        ("", True),
        (None, True),
        ("not-a-date", True),
        ("2026-08-26T10:00:00Z", False),
        ("2026-08-26T10:00:00+00:00", False),
        ("2026-08-26T10:00:00+05:30", False),  # non-UTC still parses
    ],
)
def test_parse_iso_tolerance(ts, expected_is_none) -> None:
    result = _parse_iso(ts)
    assert (result is None) == expected_is_none
