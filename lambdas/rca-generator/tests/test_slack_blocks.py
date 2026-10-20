"""Tests for rca_generator.slack_blocks — Block Kit payload shape."""

from __future__ import annotations

import json

import pytest

from rca_generator import slack_blocks
from rca_generator.schema import parse_event


def test_severity_color_known_reasons() -> None:
    assert slack_blocks.severity_color("CrashLoopBackOff") == "#d0021b"
    assert slack_blocks.severity_color("OOMKilled") == "#f5a623"
    assert slack_blocks.severity_color("ImagePullBackOff") == "#f8e71c"


def test_severity_color_unknown_falls_back_to_grey() -> None:
    assert slack_blocks.severity_color("NeverHeardOfThisReason") == "#9b9b9b"


def test_fallback_text_shape(make_event) -> None:
    incident = parse_event(make_event())
    text = slack_blocks.build_fallback_text(incident)
    assert "CrashLoopBackOff" in text
    assert incident.namespace in text
    assert incident.pod_name in text
    assert text.startswith(":rotating_light:")


def test_build_payload_valid_json_serializable(make_event) -> None:
    incident = parse_event(make_event())
    payload = slack_blocks.build_payload(incident, rca_text="Some cause. Some action.")
    body = json.dumps(payload)  # must not raise
    parsed = json.loads(body)
    assert parsed == payload


def test_build_payload_has_required_top_level_keys(make_event) -> None:
    incident = parse_event(make_event())
    payload = slack_blocks.build_payload(incident, rca_text="rca")
    assert "text" in payload
    assert "attachments" in payload
    assert isinstance(payload["attachments"], list)
    att = payload["attachments"][0]
    assert att["color"] == "#d0021b"  # CrashLoopBackOff
    assert isinstance(att["blocks"], list)
    assert att["fallback"] == payload["text"]


def test_block_kit_contains_header_context_rca_actions_footer(make_event) -> None:
    incident = parse_event(make_event())
    payload = slack_blocks.build_payload(incident, rca_text="The cause. The action.")
    blocks = payload["attachments"][0]["blocks"]
    kinds = [b["type"] for b in blocks]
    assert kinds[0] == "header"
    assert kinds[1] == "context"
    # section (message) — optional but present here
    assert "section" in kinds
    assert "actions" in kinds
    # last block is a footer context row
    assert kinds[-1] == "context"


def test_ack_button_carries_incident_id(make_event) -> None:
    incident = parse_event(make_event())
    payload = slack_blocks.build_payload(incident, rca_text="x")
    actions_block = next(
        b for b in payload["attachments"][0]["blocks"] if b["type"] == "actions"
    )
    btn = actions_block["elements"][0]
    assert btn["type"] == "button"
    assert btn["action_id"] == "smartops_acknowledge"
    assert btn["value"] == incident.incident_id
    assert btn["text"]["text"] == "Acknowledge"


def test_message_block_omitted_when_empty(make_event) -> None:
    incident = parse_event(make_event(message=""))
    payload = slack_blocks.build_payload(incident, rca_text="x")
    blocks = payload["attachments"][0]["blocks"]
    # No section block whose text starts with "*Message*"
    msg_blocks = [
        b for b in blocks
        if b["type"] == "section" and "*Message*" in b.get("text", {}).get("text", "")
    ]
    assert msg_blocks == []


def test_rca_label_reflects_source(make_event) -> None:
    incident = parse_event(make_event())
    p_groq = slack_blocks.build_payload(incident, rca_text="x", rca_source="groq")
    p_fb = slack_blocks.build_payload(incident, rca_text="x", rca_source="fallback")

    def find_rca_block(p: dict) -> dict:
        return next(
            b for b in p["attachments"][0]["blocks"]
            if b["type"] == "section"
            and "*RCA" in b.get("text", {}).get("text", "")
        )

    assert "*RCA*" in find_rca_block(p_groq)["text"]["text"]
    assert "*RCA (fallback)*" in find_rca_block(p_fb)["text"]["text"]


def test_long_rca_truncated(make_event) -> None:
    incident = parse_event(make_event())
    long_text = "x" * 5000
    payload = slack_blocks.build_payload(incident, rca_text=long_text)
    rca_block = next(
        b for b in payload["attachments"][0]["blocks"]
        if b["type"] == "section" and "*RCA" in b.get("text", {}).get("text", "")
    )
    # Truncation must have happened
    assert len(rca_block["text"]["text"]) < len(long_text) + 200
    assert "\u2026" in rca_block["text"]["text"]  # ellipsis


def test_zone_and_exit_code_conditional(make_event) -> None:
    incident_no_zone = parse_event(make_event(zone=None, exitCode=None))
    payload = slack_blocks.build_payload(incident_no_zone, rca_text="x")
    ctx_text = payload["attachments"][0]["blocks"][1]["elements"][0]["text"]
    assert "*zone*" not in ctx_text
    assert "*exit*" not in ctx_text

    incident_with = parse_event(make_event(zone="us-east-1a", exitCode=137))
    payload = slack_blocks.build_payload(incident_with, rca_text="x")
    ctx_text = payload["attachments"][0]["blocks"][1]["elements"][0]["text"]
    assert "us-east-1a" in ctx_text
    assert "137" in ctx_text
