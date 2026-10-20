"""Groq LLM client for root-cause analysis text generation.

Uses Groq's OpenAI-compatible chat-completions endpoint. Everything goes
through stdlib `urllib.request` so we don't add any external dependency
to the deployment package (keeps the Lambda zip < 60 KB even with Module 6).

Design notes:
  - **Fail-soft.** Any HTTP error, timeout, or malformed response returns
    None so the handler falls back to the Module 5.0 placeholder text.
    LLM outages MUST NOT block incident persistence.
  - **Cost-safe.** `max_tokens` capped, `temperature` low. A runaway prompt
    can't burn free-tier quota.
  - **Prompt is data.** Built as a function of the parsed Incident so the
    upstream schema (Module 4 v1.0) is the single source of truth for what
    the model sees.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request

from rca_generator.schema import Incident

log = logging.getLogger(__name__)

GROQ_URL = "https://api.groq.com/openai/v1/chat/completions"

SYSTEM_PROMPT = (
    "You are a senior Site Reliability Engineer analyzing a Kubernetes pod "
    "failure. You must respond in TWO sentences maximum:\n"
    "  1. A one-sentence root-cause hypothesis based on the observable signal.\n"
    "  2. A one-sentence recommended next action (kubectl command, code check, "
    "or config to inspect).\n"
    "Be specific to the reason. Never speculate beyond the evidence. Never "
    "include headings, bullets, code fences, or apologies. Plain text only."
)


def build_user_prompt(incident: Incident) -> str:
    """Structured, machine-friendly prompt. Order + labels matter for the model."""
    lines = [
        "Kubernetes pod-failure incident:",
        f"  reason:         {incident.reason}",
        f"  namespace:      {incident.namespace}",
        f"  pod:            {incident.pod_name}",
        f"  container:      {incident.container_name}",
        f"  restart_count:  {incident.restart_count}",
        f"  exit_code:      {incident.exit_code if incident.exit_code is not None else 'n/a'}",
        f"  node:           {incident.node_name}",
        f"  zone:           {incident.zone or 'n/a'}",
        f"  timestamp:      {incident.timestamp}",
        f"  kubelet msg:    {incident.message or '(empty)'}",
    ]
    if incident.labels:
        # Only include the most useful labels to keep prompt short + focused.
        interesting = ("app.kubernetes.io/name", "app.kubernetes.io/component")
        chosen = {k: v for k, v in incident.labels.items() if k in interesting}
        if chosen:
            lines.append(f"  labels:         {json.dumps(chosen)}")

    lines.append("")
    lines.append("Analyze and respond in two sentences (cause + next action).")
    return "\n".join(lines)


def generate_rca(
    incident: Incident,
    *,
    api_key: str | None,
    model: str,
    timeout_seconds: int = 10,
    max_tokens: int = 200,
    temperature: float = 0.2,
) -> str | None:
    """Call Groq. Returns the RCA text on success, None on any failure (fail-soft)."""
    if not api_key:
        log.info("groq disabled (no api_key) — skipping LLM", extra={
            "incident_id": incident.incident_id,
        })
        return None

    body = json.dumps({
        "model": model,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": build_user_prompt(incident)},
        ],
    }).encode("utf-8")

    req = urllib.request.Request(
        GROQ_URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
            "User-Agent": "smartops-rca-generator/0.1",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=timeout_seconds) as resp:
            status = resp.status
            payload = resp.read().decode("utf-8")
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as e:
        log.warning("groq call failed (soft)", extra={
            "incident_id": incident.incident_id, "error": str(e),
        })
        return None

    if not 200 <= status < 300:
        log.warning("groq non-2xx", extra={
            "incident_id": incident.incident_id, "status": status, "body": payload[:500],
        })
        return None

    try:
        data = json.loads(payload)
        text = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, json.JSONDecodeError, TypeError) as e:
        log.warning("groq response malformed (soft)", extra={
            "incident_id": incident.incident_id, "error": str(e), "body": payload[:500],
        })
        return None

    text = (text or "").strip()
    if not text:
        log.warning("groq returned empty text (soft)", extra={
            "incident_id": incident.incident_id,
        })
        return None

    log.info("groq rca generated", extra={
        "incident_id": incident.incident_id,
        "model": model,
        "chars": len(text),
    })
    return text
