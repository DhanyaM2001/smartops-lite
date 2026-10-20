"""Tests for remediator.slack — response payload shape."""

from __future__ import annotations

from remediator import slack


def _original_message() -> dict:
    return {
        "text": "SmartOps incident",
        "blocks": [
            {"type": "header", "text": {"type": "plain_text", "text": "hi"}},
            {"type": "section", "text": {"type": "mrkdwn", "text": "context"}},
            {
                "type": "actions",
                "block_id": "smartops_actions",
                "elements": [{"type": "button", "action_id": "smartops_acknowledge"}],
            },
            {"type": "context", "elements": [{"type": "mrkdwn", "text": "footer"}]},
        ],
    }


def test_ack_response_replaces_original() -> None:
    body = slack.build_ack_response(
        original_message=_original_message(),
        actor="U0DEV",
        when="2026-08-25T10:00:00Z",
    )
    assert body["replace_original"] is True
    assert body["text"] == "SmartOps incident"


def test_ack_response_removes_action_block() -> None:
    body = slack.build_ack_response(
        original_message=_original_message(), actor="U0X", when="ts",
    )
    block_ids = [b.get("block_id") for b in body["blocks"]]
    assert "smartops_actions" not in block_ids
    # New footer added
    assert "smartops_ack_footer" in block_ids


def test_ack_footer_names_actor_and_time() -> None:
    body = slack.build_ack_response(
        original_message=_original_message(),
        actor="U0DEV",
        when="2026-08-25T10:00:00Z",
    )
    footer = next(b for b in body["blocks"] if b.get("block_id") == "smartops_ack_footer")
    text = footer["elements"][0]["text"]
    assert "<@U0DEV>" in text
    assert "2026-08-25T10:00:00Z" in text
    assert "Acknowledged" in text
    assert "(already)" not in text  # first-ack path


def test_already_ack_response_marks_replay() -> None:
    body = slack.build_already_ack_response(
        original_message=_original_message(),
        prior_actor="U0FIRST",
        prior_when="2026-08-25T09:00:00Z",
    )
    footer = next(b for b in body["blocks"] if b.get("block_id") == "smartops_ack_footer")
    text = footer["elements"][0]["text"]
    assert "<@U0FIRST>" in text
    assert "already" in text.lower()


def test_original_blocks_preserved_except_actions() -> None:
    """Every non-actions block from the original must survive verbatim."""
    orig = _original_message()
    body = slack.build_ack_response(original_message=orig, actor="U0X", when="t")
    preserved = [b for b in body["blocks"] if b.get("block_id") != "smartops_ack_footer"]
    expected = [b for b in orig["blocks"] if b.get("block_id") != "smartops_actions"]
    assert preserved == expected


def test_empty_blocks_handled() -> None:
    body = slack.build_ack_response(
        original_message={"blocks": [], "text": "x"}, actor="U0X", when="t",
    )
    assert len(body["blocks"]) == 1  # just the footer
    assert body["blocks"][0]["block_id"] == "smartops_ack_footer"


def test_error_response_is_ephemeral() -> None:
    body = slack.build_error_response()
    assert body["response_type"] == "ephemeral"
    assert body["replace_original"] is False
    assert body["text"].startswith(":warning:")


def _original_attachment_message() -> dict:
    """Slack echoes attachment-wrapped cards as message.attachments[*].blocks.

    This mirrors what rca-generator's slack_blocks.py actually posts (Block Kit
    lives under attachments[0].blocks so Slack renders the coloured left bar).
    """
    return {
        "text": "SmartOps incident",
        "attachments": [
            {
                "color": "#dc3545",
                "blocks": [
                    {"type": "header", "text": {"type": "plain_text", "text": "hi"}},
                    {"type": "section", "text": {"type": "mrkdwn", "text": "context"}},
                    {
                        "type": "actions",
                        "block_id": "smartops_actions",
                        "elements": [{"type": "button", "action_id": "smartops_acknowledge"}],
                    },
                    {"type": "context", "elements": [{"type": "mrkdwn", "text": "footer"}]},
                ],
            }
        ],
    }


def test_ack_response_reads_attachment_blocks_when_top_level_missing() -> None:
    """Regression for audit bug P-3: without this branch, attachment-nested
    Block Kit cards produced by rca-generator lost their body on ack — the
    reply arrived with only the footer and no incident context.
    """
    body = slack.build_ack_response(
        original_message=_original_attachment_message(),
        actor="U0DEV",
        when="2026-08-25T10:00:00Z",
    )
    block_ids = [b.get("block_id") for b in body["blocks"]]
    # Header + section + context + new footer = 4 blocks; actions stripped.
    assert len(body["blocks"]) == 4
    assert "smartops_actions" not in block_ids
    assert "smartops_ack_footer" in block_ids


def test_top_level_blocks_take_precedence_over_attachments() -> None:
    """If Slack sends BOTH shapes, the top-level list wins (older behavior)."""
    msg = _original_message()
    msg["attachments"] = [{"blocks": [{"type": "divider"}]}]  # sentinel
    body = slack.build_ack_response(
        original_message=msg, actor="U0X", when="t",
    )
    types = [b.get("type") for b in body["blocks"]]
    assert "divider" not in types  # attachment sentinel MUST NOT leak in
