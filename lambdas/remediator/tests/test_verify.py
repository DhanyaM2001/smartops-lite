"""Tests for remediator.verify — Slack HMAC + timestamp window."""

from __future__ import annotations

import hashlib
import hmac
import time

import pytest

from remediator import verify
from tests.conftest import SIGNING_SECRET, sign_body


def test_valid_signature_returns_none() -> None:
    body = b"payload=%7B%7D"
    headers = sign_body(body)
    assert (
        verify.verify(
            raw_body=body,
            timestamp_header=headers["X-Slack-Request-Timestamp"],
            signature_header=headers["X-Slack-Signature"],
            signing_secret=SIGNING_SECRET,
        )
        is None
    )


def test_missing_signing_secret_raises() -> None:
    with pytest.raises(verify.VerificationError, match="signing_secret"):
        verify.verify(
            raw_body=b"",
            timestamp_header=str(int(time.time())),
            signature_header="v0=x",
            signing_secret=None,
        )


def test_missing_timestamp_raises() -> None:
    # Actual error text is "missing X-Slack-Request-Timestamp" — regex
    # match is case-sensitive by default, so we anchor on the header name.
    with pytest.raises(verify.VerificationError, match="Timestamp"):
        verify.verify(
            raw_body=b"",
            timestamp_header=None,
            signature_header="v0=x",
            signing_secret=SIGNING_SECRET,
        )


def test_missing_signature_raises() -> None:
    with pytest.raises(verify.VerificationError, match="Signature"):
        verify.verify(
            raw_body=b"",
            timestamp_header=str(int(time.time())),
            signature_header=None,
            signing_secret=SIGNING_SECRET,
        )


def test_non_integer_timestamp_raises() -> None:
    with pytest.raises(verify.VerificationError, match="non-integer"):
        verify.verify(
            raw_body=b"",
            timestamp_header="not-a-number",
            signature_header="v0=x",
            signing_secret=SIGNING_SECRET,
        )


def test_stale_timestamp_rejected() -> None:
    body = b"payload=%7B%7D"
    stale_ts = int(time.time()) - 3600  # 1h ago
    headers = sign_body(body, ts=stale_ts)
    with pytest.raises(verify.VerificationError, match="stale"):
        verify.verify(
            raw_body=body,
            timestamp_header=headers["X-Slack-Request-Timestamp"],
            signature_header=headers["X-Slack-Signature"],
            signing_secret=SIGNING_SECRET,
            replay_window_seconds=300,
        )


def test_future_timestamp_rejected() -> None:
    body = b""
    future_ts = int(time.time()) + 3600
    headers = sign_body(body, ts=future_ts)
    with pytest.raises(verify.VerificationError, match="stale"):
        verify.verify(
            raw_body=body,
            timestamp_header=headers["X-Slack-Request-Timestamp"],
            signature_header=headers["X-Slack-Signature"],
            signing_secret=SIGNING_SECRET,
            replay_window_seconds=300,
        )


def test_wrong_signing_secret_rejected() -> None:
    body = b"payload=%7B%7D"
    ts = int(time.time())
    basestring = f"v0:{ts}:".encode() + body
    bogus = "v0=" + hmac.new(b"wrong-secret", basestring, hashlib.sha256).hexdigest()
    with pytest.raises(verify.VerificationError, match="hmac"):
        verify.verify(
            raw_body=body,
            timestamp_header=str(ts),
            signature_header=bogus,
            signing_secret=SIGNING_SECRET,
        )


def test_body_tampering_rejected() -> None:
    body = b"payload=%7B%22original%22%3Atrue%7D"
    headers = sign_body(body)  # sig computed for original body
    tampered = b"payload=%7B%22tampered%22%3Atrue%7D"
    with pytest.raises(verify.VerificationError, match="hmac"):
        verify.verify(
            raw_body=tampered,  # different body
            timestamp_header=headers["X-Slack-Request-Timestamp"],
            signature_header=headers["X-Slack-Signature"],
            signing_secret=SIGNING_SECRET,
        )


def test_constant_time_compare_used() -> None:
    """Sanity: `hmac.compare_digest` is what's imported (defense-in-depth)."""
    import inspect
    src = inspect.getsource(verify.verify)
    assert "compare_digest" in src


def test_now_epoch_override_works() -> None:
    body = b"x"
    ts = 1_000_000_000  # arbitrary epoch
    headers = sign_body(body, ts=ts)
    # Without override, this would be "stale". With override, it's fresh.
    verify.verify(
        raw_body=body,
        timestamp_header=headers["X-Slack-Request-Timestamp"],
        signature_header=headers["X-Slack-Signature"],
        signing_secret=SIGNING_SECRET,
        now_epoch=ts,
    )
