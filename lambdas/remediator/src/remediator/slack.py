"""Slack response payload builders.

When a user clicks a block button, Slack POSTs the interaction payload
to our Lambda URL. We reply immediately with a JSON body that replaces
the original message — much simpler than the response_url dance.

Two response shapes:
  - **build_ack_response(actor, when)** — successful ack. Replaces the
    "Acknowledge" button with an "✔ Acknowledged by @actor at <time>"
    context row while keeping all other blocks intact.
  - **build_already_ack_response(prior_actor, prior_when)** — double-click.
    Similar shape but tells the user who acknowledged FIRST.

We rebuild the message on the fly rather than trying to edit blocks in
place because Slack sends us the ENTIRE original `message.blocks` in the
interaction payload — we just filter out the actions block and append
our own footer.
"""

from __future__ import annotations

from typing import Any


def _extract_blocks(message: dict[str, Any]) -> list[dict[str, Any]]:
    """Return the Block Kit blocks Slack sent us, wherever it put them.

    The rca-generator publishes cards using the `attachments` shape:
      { "text": "...", "attachments": [ { "blocks": [ ... ] } ] }
    Slack's interaction callback echoes the message back under
    `message.blocks` for top-level blocks but keeps attachment-nested
    blocks under `message.attachments[*].blocks`. If we only looked at
    `message.blocks`, the ack response would arrive with an empty body
    (bug P-3 in the end-to-end audit). Try top-level first, then flatten
    every attachment's blocks in order.
    """
    top_level = message.get("blocks")
    if top_level:
        return list(top_level)
    flattened: list[dict[str, Any]] = []
    for att in message.get("attachments", []) or []:
        for b in att.get("blocks", []) or []:
            flattened.append(b)
    return flattened


def _strip_actions_block(blocks: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Remove the block with `block_id: smartops_actions` (the button row)."""
    return [b for b in blocks if b.get("block_id") != "smartops_actions"]


def _ack_context(actor: str, when: str, *, is_replay: bool = False) -> dict[str, Any]:
    """Green ✔ context row replacing the button."""
    prefix = ":white_check_mark: *Acknowledged"
    if is_replay:
        prefix += " (already)"
    return {
        "type": "context",
        "block_id": "smartops_ack_footer",
        "elements": [
            {"type": "mrkdwn", "text": f"{prefix}* by <@{actor}> at `{when}`"},
        ],
    }


def build_ack_response(
    *,
    original_message: dict[str, Any],
    actor: str,
    when: str,
) -> dict[str, Any]:
    """Body to return to Slack after a successful ack. Replaces original."""
    original_blocks = _extract_blocks(original_message)
    new_blocks = _strip_actions_block(original_blocks)
    new_blocks.append(_ack_context(actor, when, is_replay=False))
    return {
        "replace_original": True,
        "text": original_message.get("text", "SmartOps incident acknowledged"),
        "blocks": new_blocks,
    }


def build_already_ack_response(
    *,
    original_message: dict[str, Any],
    prior_actor: str,
    prior_when: str,
) -> dict[str, Any]:
    """Same shape but names the *first* acknowledger."""
    original_blocks = _extract_blocks(original_message)
    new_blocks = _strip_actions_block(original_blocks)
    new_blocks.append(_ack_context(prior_actor, prior_when, is_replay=True))
    return {
        "replace_original": True,
        "text": original_message.get("text", "SmartOps incident already acknowledged"),
        "blocks": new_blocks,
    }


def build_error_response(
    *,
    message: str = "SmartOps could not process this action. Check the incident logs.",
) -> dict[str, Any]:
    """Ephemeral error toast — only the clicker sees it."""
    return {
        "response_type": "ephemeral",
        "text": f":warning: {message}",
        "replace_original": False,
    }
