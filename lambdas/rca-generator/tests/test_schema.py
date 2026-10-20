"""Unit tests for rca_generator.schema.parse_event."""

from __future__ import annotations

import pytest

from rca_generator.schema import Incident, SchemaError, parse_event


def test_parses_v1_event(make_event) -> None:
    incident = parse_event(make_event())
    assert isinstance(incident, Incident)
    assert incident.incident_id == "b48b9a2d-e46c-4c1a-9f26-1d2d78d15f39"
    assert incident.reason == "CrashLoopBackOff"
    assert incident.restart_count == 5
    assert incident.labels == {"app.kubernetes.io/name": "crashy-app"}
    assert incident.zone == "ap-south-1a"


def test_rejects_wrong_source(make_event) -> None:
    ev = make_event()
    ev["source"] = "aws.s3"
    with pytest.raises(SchemaError, match="source"):
        parse_event(ev)


def test_rejects_wrong_detail_type(make_event) -> None:
    ev = make_event()
    ev["detail-type"] = "NotAnIncident"
    with pytest.raises(SchemaError, match="detail-type"):
        parse_event(ev)


def test_rejects_missing_detail(make_event) -> None:
    ev = make_event()
    ev.pop("detail")
    with pytest.raises(SchemaError, match="detail"):
        parse_event(ev)


def test_rejects_unknown_schema_version(make_event) -> None:
    ev = make_event(schemaVersion="99.9")
    with pytest.raises(SchemaError, match="schemaVersion"):
        parse_event(ev)


@pytest.mark.parametrize(
    "field", ["incidentId", "namespace", "podName", "containerName", "reason", "timestamp"]
)
def test_rejects_missing_required_field(make_event, field: str) -> None:
    ev = make_event(**{field: None})
    with pytest.raises(SchemaError, match=field):
        parse_event(ev)


def test_optional_fields_default(make_event) -> None:
    ev = make_event(zone=None, exitCode=None, labels={}, podUid=None, nodeName=None)
    incident = parse_event(ev)
    assert incident.zone is None
    assert incident.exit_code is None
    assert incident.labels == {}
    assert incident.pod_uid == ""
    assert incident.node_name == "unknown"


def test_exit_code_coerced_to_int(make_event) -> None:
    ev = make_event(exitCode="137")
    incident = parse_event(ev)
    assert incident.exit_code == 137


def test_labels_reject_wrong_type(make_event) -> None:
    ev = make_event(labels="not-a-dict")
    with pytest.raises(SchemaError, match="labels"):
        parse_event(ev)


def test_restart_count_reject_wrong_type(make_event) -> None:
    ev = make_event(restartCount="not-a-number")
    with pytest.raises(SchemaError, match="restartCount"):
        parse_event(ev)


def test_event_must_be_dict() -> None:
    with pytest.raises(SchemaError):
        parse_event(["not", "a", "dict"])  # type: ignore[arg-type]
