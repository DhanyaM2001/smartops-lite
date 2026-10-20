"""Slack Block Kit builder for the RCA-generator notification.

Payload shape follows Slack's incoming-webhook contract:
  - `text` is the fallback for notifications / clients that can't render blocks
  - `attachments[0].color` is the vertical stripe color (severity hint)
  - `attachments[0].blocks` is the rich content

The 'Acknowledge' button carries an `action_id` and `value` — Module 7 will
add the SNS/Lambda subscriber that receives the button click and reacts.
Until then the button is decorative but harmless (Slack silently accepts
clicks on unroutable actions).

Design notes:
  - **Determinism over cleverness.** Severity is a lookup on `reason`, not
    a heuristic. Adding a new reason just means adding a row to the map.
  - **~2 KB payload cap.** Block Kit rejects very large payloads; we cap
    the RCA text and truncate labels rather than risk a rejection at
    incident time.
  - **Fallback text is meaningful.** Notifications on mobile show the
    fallback, not the blocks — so it must stand alone.
"""

from __future__ import annotations

from typing import Any

from rca_generator.schema import Incident

# Slack "attachment color" per incident reason. Hex codes match what
# reviewers expect from familiar tools (red = crash, orange = OOM,
# yellow = image issue, grey = other).
_SEVERITY_COLOR: dict[str, str] = {
    "CrashLoopBackOff":           "#d0021b",  # red
    "OOMKilled":                  "#f5a623",  # orange
    "Error":                      "#d0021b",  # red — non-zero exit
    "ImagePullBackOff":           "#f8e71c",  # yellow
    "ErrImagePull":               "#f8e71c",
    "ErrImageNeverPull":          "#f8e71c",
    "CreateContainerConfigError": "#f5a623",
    "CreateContainerError":       "#f5a623",
    "RunContainerError":          "#f5a623",
    "PodFailed":                  "#d0021b",
}
_DEFAULT_COLOR = "#9b9b9b"  # grey — unknown reason

# Block Kit's plain-text limits (Slack rejects blocks > these). Keep some
# headroom for markdown escapes.
MAX_RCA_CHARS = 900
MAX_MESSAGE_CHARS = 500
MAX_LABEL_CHARS = 200


def severity_color(reason: str) -> str:
    """Public helper so tests can assert without importing the private map."""
    return _SEVERITY_COLOR.get(reason, _DEFAULT_COLOR)


def _truncate(s: str, n: int) -> str:
    return s if len(s) <= n else s[: n - 1] + "\u2026"  # ellipsis


def build_fallback_text(incident: Incident) -> str:
    """Notification-tray text — mobile shows only this."""
    return (
        f":rotating_light: SmartOps: {incident.reason} in "
        f"{incident.namespace}/{incident.pod_name}"
    )


def build_payload(
    incident: Incident,
    *,
    rca_text: str,
    rca_source: str = "groq",
) -> dict[str, Any]:
    """Build the full Slack webhook payload — call Slack with this as JSON body."""
    color = severity_color(incident.reason)
    fallback = build_fallback_text(incident)

    # ---- Header ----
    header_block = {
        "type": "header",
        "text": {
            "type": "plain_text",
            "text": f":rotating_light: {incident.reason} — {incident.namespace}/{incident.pod_name}",
            "emoji": True,
        },
    }

    # ---- Context row: node + zone + restarts + exit code ----
    context_parts = [
        f"*container* `{incident.container_name}`",
        f"*restarts* `{incident.restart_count}`",
        f"*node* `{incident.node_name}`",
    ]
    if incident.zone:
        context_parts.append(f"*zone* `{incident.zone}`")
    if incident.exit_code is not None:
        context_parts.append(f"*exit* `{incident.exit_code}`")

    context_block = {
        "type": "context",
        "elements": [
            {"type": "mrkdwn", "text": "  ·  ".join(context_parts)},
        ],
    }

    # ---- Kubelet message (if any) ----
    blocks: list[dict[str, Any]] = [header_block, context_block]

    if incident.message:
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*Message*\n```{_truncate(incident.message, MAX_MESSAGE_CHARS)}```",
            },
        })

    # ---- RCA block ----
    rca_label = "RCA" if rca_source == "groq" else "RCA (fallback)"
    blocks.append({
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": f"*{rca_label}*\n{_truncate(rca_text, MAX_RCA_CHARS)}",
        },
    })

    # ---- Actions: acknowledge button (Module 7 wires the receiver) ----
    blocks.append({
        "type": "actions",
        "block_id": "smartops_actions",
        "elements": [
            {
                "type": "button",
                "text": {"type": "plain_text", "text": "Acknowledge", "emoji": False},
                "style": "primary",
                "action_id": "smartops_acknowledge",
                "value": incident.incident_id,
            },
        ],
    })

    # ---- Footer / metadata ----
    blocks.append({
        "type": "context",
        "elements": [
            {
                "type": "mrkdwn",
                "text": (
                    f"incident `{incident.incident_id}`  ·  "
                    f"schema `v{incident.schema_version}`  ·  "
                    f"{incident.timestamp}"
                ),
            },
        ],
    })

    return {
        "text": fallback,
        "attachments": [
            {
                "color": color,
                "blocks": blocks,
                "fallback": fallback,  # legacy clients
            },
        ],
    }
