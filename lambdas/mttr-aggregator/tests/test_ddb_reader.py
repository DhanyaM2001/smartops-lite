"""ddb_reader tests — moto DDB."""

from __future__ import annotations

from datetime import timedelta

from mttr_aggregator.ddb_reader import _av_to_python, _unmarshall, scan_recent


def test_unmarshall_covers_written_shapes() -> None:
    item = {
        "incidentId": {"S": "inc-1"},
        "restartCount": {"N": "5"},
        "labels": {"M": {"app": {"S": "crashy"}}},
        "exitCode": {"NULL": True},
    }
    out = _unmarshall(item)
    assert out["incidentId"] == "inc-1"
    assert out["restartCount"] == 5
    assert out["labels"] == {"app": "crashy"}
    assert out["exitCode"] is None


def test_av_to_python_number_variants() -> None:
    assert _av_to_python({"N": "42"}) == 42
    assert _av_to_python({"N": "42.5"}) == 42.5


def test_scan_recent_filters_by_window(aws_mocks, seed_ddb, now_utc) -> None:
    from tests.conftest import TABLE_NAME

    seed_ddb([
        {"ingested_minutes_ago": 5, "acked_minutes_ago": 2},    # in window
        {"ingested_minutes_ago": 45, "acked_minutes_ago": 40},  # in window
        {"ingested_minutes_ago": 90, "acked_minutes_ago": 85},  # OUT of 60-min window
    ])

    rows = scan_recent(
        table_name=TABLE_NAME,
        ddb_client=aws_mocks["ddb"],
        window_minutes=60,
        now_utc=now_utc,
    )
    assert len(rows) == 2
    for r in rows:
        assert "ingestedAt" in r
        assert "acknowledgedAt" in r
        assert isinstance(r["restartCount"], int)


def test_scan_recent_handles_empty_table(aws_mocks, now_utc) -> None:
    from tests.conftest import TABLE_NAME

    rows = scan_recent(
        table_name=TABLE_NAME,
        ddb_client=aws_mocks["ddb"],
        window_minutes=60,
        now_utc=now_utc,
    )
    assert rows == []


def test_scan_recent_narrow_window_excludes_old_rows(aws_mocks, seed_ddb, now_utc) -> None:
    from tests.conftest import TABLE_NAME

    seed_ddb([
        {"ingested_minutes_ago": 3},
        {"ingested_minutes_ago": 8},   # OUT of 5-min window
    ])
    rows = scan_recent(
        table_name=TABLE_NAME,
        ddb_client=aws_mocks["ddb"],
        window_minutes=5,
        now_utc=now_utc,
    )
    assert len(rows) == 1
