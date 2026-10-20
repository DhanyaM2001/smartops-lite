"""Tests for rca_generator.persistence (Module 5.0 + Module 6 rca fields)."""

from __future__ import annotations

from rca_generator.persistence import (
    RCA_PLACEHOLDER,
    _marshall,
    _to_attr_value,
    build_item,
    persist,
)
from rca_generator.schema import parse_event
from tests.conftest import TABLE_NAME


def test_marshall_types() -> None:
    """Every value type this Lambda produces must map to a valid AV."""
    assert _to_attr_value(None) == {"NULL": True}
    assert _to_attr_value("hello") == {"S": "hello"}
    assert _to_attr_value("") == {"NULL": True}  # DDB rejects "" — coerce
    assert _to_attr_value(42) == {"N": "42"}
    assert _to_attr_value(True) == {"BOOL": True}
    assert _to_attr_value({"k": "v"}) == {"M": {"k": {"S": "v"}}}
    assert _to_attr_value([1, "two"]) == {"L": [{"N": "1"}, {"S": "two"}]}


def test_build_item_default_placeholder(make_event) -> None:
    """No RCA kwargs → Module 5.0-compatible pending row."""
    incident = parse_event(make_event())
    item = build_item(incident, now_iso="2026-08-24T10:20:00Z")
    assert item["ingestedAt"] == "2026-08-24T10:20:00Z"
    assert item["rcaStatus"] == "pending"
    assert item["rcaSource"] == "none"
    assert item["rcaText"] == RCA_PLACEHOLDER


def test_build_item_with_llm_rca(make_event) -> None:
    incident = parse_event(make_event())
    item = build_item(
        incident,
        rca_text="The container crashed. Restart the pod.",
        rca_status="generated",
        rca_source="groq",
    )
    assert item["rcaStatus"] == "generated"
    assert item["rcaSource"] == "groq"
    assert item["rcaText"] == "The container crashed. Restart the pod."


def test_persist_round_trip_with_rca(aws_mocks, make_event) -> None:
    incident = parse_event(make_event())
    persist(
        incident,
        table_name=TABLE_NAME,
        ddb_client=aws_mocks["ddb"],
        rca_text="A cause. An action.",
        rca_status="generated",
        rca_source="groq",
    )

    row = aws_mocks["ddb"].get_item(
        TableName=TABLE_NAME,
        Key={"incidentId": {"S": incident.incident_id}},
    )
    got = row["Item"]
    assert got["rcaStatus"]["S"] == "generated"
    assert got["rcaSource"]["S"] == "groq"
    assert got["rcaText"]["S"] == "A cause. An action."


def test_persist_is_idempotent(aws_mocks, make_event) -> None:
    incident = parse_event(make_event())
    persist(incident, table_name=TABLE_NAME, ddb_client=aws_mocks["ddb"])
    persist(incident, table_name=TABLE_NAME, ddb_client=aws_mocks["ddb"])

    scan = aws_mocks["ddb"].scan(TableName=TABLE_NAME)
    assert scan["Count"] == 1


def test_marshall_handles_optional_null_exit_code(make_event) -> None:
    incident = parse_event(make_event(exitCode=None))
    item = build_item(incident)
    av = _marshall(item)
    assert av["exitCode"] == {"NULL": True}


def test_backwards_compat_module5_persist_signature(
    aws_mocks, make_event
) -> None:
    """persist() with no rca_* kwargs still works — Module 5.0 call sites unchanged."""
    incident = parse_event(make_event())
    persist(incident, table_name=TABLE_NAME, ddb_client=aws_mocks["ddb"])
    row = aws_mocks["ddb"].get_item(
        TableName=TABLE_NAME, Key={"incidentId": {"S": incident.incident_id}}
    )
    assert row["Item"]["rcaStatus"]["S"] == "pending"
