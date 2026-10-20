"""Slack request signature verification (HMAC-SHA256).

Slack signs every request with a signing secret to prove it originated
from the Slack app registered with that secret. Per Slack's docs
(https://api.slack.com/authentication/verifying-requests-from-slack):

    sig_basestring = f"v0:{X-Slack-Request-Timestamp}:{raw_body}"
    expected      = "v0=" + HMAC-SHA256(signing_secret, sig_basestring)
    compare to X-Slack-Signature via constant-time compare

We also reject stale timestamps to mitigate replay attacks: Slack itself
recommends a 5-minute window (`REPLAY_WINDOW_SECONDS`).

Everything here is pure — no I/O, no dependencies. `verify()` returns a
tagged error string on rejection so the caller can log + return 401.
"""

from __future__ import annotations

import hashlib
import hmac
import logging
import time

log = logging.getLogger(__name__)

# Public sentinel — caller pattern-matches on it to distinguish "reject
# but do not retry" (all cases here) from "5xx and retry" (DDB/bus).
class VerificationError(Exception):
    """Signature or timestamp verification failed."""


def verify(
    *,
    raw_body: bytes,
    timestamp_header: str | None,
    signature_header: str | None,
    signing_secret: str | None,
    replay_window_seconds: int = 300,
    now_epoch: int | None = None,
) -> None:
    """Raise VerificationError on any failure. Return None on success.

    Every failure mode is a security signal — logged but never leaks
    detail to the response body.
    """
    if not signing_secret:
        raise VerificationError("signing_secret not loaded (SSM miss?)")

    if not timestamp_header:
        raise VerificationError("missing X-Slack-Request-Timestamp")

    if not signature_header:
        raise VerificationError("missing X-Slack-Signature")

    # ---- Timestamp window ----
    try:
        ts_int = int(timestamp_header)
    except ValueError as e:
        raise VerificationError(f"non-integer timestamp {timestamp_header!r}") from e

    now = now_epoch if now_epoch is not None else int(time.time())
    if abs(now - ts_int) > replay_window_seconds:
        raise VerificationError(
            f"stale timestamp (delta={now - ts_int}s, window={replay_window_seconds}s)"
        )

    # ---- HMAC compare ----
    basestring = f"v0:{timestamp_header}:".encode("utf-8") + raw_body
    computed = "v0=" + hmac.new(
        signing_secret.encode("utf-8"), basestring, hashlib.sha256
    ).hexdigest()

    # Constant-time compare — no early exit on first byte mismatch.
    if not hmac.compare_digest(computed, signature_header):
        raise VerificationError("hmac mismatch")

    return None
