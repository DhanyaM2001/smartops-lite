"""Pure aggregation logic — no I/O, no AWS. Fully unit-testable.

Input:  list[dict] of DDB rows (already unmarshalled — caller does the DDB
        deserialization). Each row has the shape written by
        `rca-generator.persistence.build_item()` plus optional
        `acknowledgedAt`/`acknowledgedBy` from the remediator.
Output: list[Metric] ready for the publisher to push to CloudWatch.

Design decisions
----------------
1. **Free-tier compliance is a hard constraint.** CloudWatch's free tier is
   10 custom metric series/month; we emit exactly 5 no-dimension series so
   the dashboard is genuinely free at demo scale.

   Metric series emitted (all no-dimension):
     - `IncidentCount`         — total in window
     - `AckedIncidentCount`    — total acknowledged in window
     - `MTTRSecondsAvg`        — avg ack latency
     - `AckRatePercent`        — 100 * acked / total
     - `LLMSuccessRatePercent` — 100 * (rcaSource==groq) / total

   Per-reason and per-source breakouts are still available in the Grafana
   dashboard — they come from CloudWatch Logs Insights queries against
   the existing rca-generator log group (free within the 5 GB ingest
   allowance), not from custom metrics.

2. **MTTR is computed ONLY from rows that have both `ingestedAt` AND
   `acknowledgedAt`.** Rows without an ack are counted in `IncidentCount`
   but excluded from MTTR (they'd bias the average toward the window
   boundary).

3. **Zero-fill only when empty.** On an empty window we emit
   `IncidentCount=0` so Grafana doesn't leave a gap in the chart.
   Everywhere else, if the denominator is 0 we skip the metric.

4. **Timestamps in DDB are RFC3339 UTC (`…Z`).** We parse tolerantly (both
   `…Z` and `…+00:00`); unparseable values are treated as missing.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any


@dataclass(frozen=True)
class Metric:
    """A single CloudWatch metric datum ready to publish."""

    name: str
    value: float
    unit: str  # CloudWatch unit: "Seconds" | "Count" | "Percent"
    dimensions: dict[str, str]  # kept for API symmetry — always {} in Module 9


def _parse_iso(ts: str | None) -> datetime | None:
    """Parse RFC3339 ISO timestamp — return None if missing or unparseable."""
    if not ts:
        return None
    try:
        # Accept both "…Z" and "…+00:00" — normalize.
        if ts.endswith("Z"):
            ts = ts[:-1] + "+00:00"
        dt = datetime.fromisoformat(ts)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt
    except (ValueError, TypeError):
        return None


def aggregate(
    rows: list[dict[str, Any]],
    *,
    now_utc: datetime | None = None,
) -> list[Metric]:
    """Turn a list of DDB rows into a free-tier-safe list of Metrics.

    `now_utc` is unused today but reserved for future window-based logic
    (e.g. "count only rows ingested in last N minutes"). Kept in signature
    for callers so future changes don't need a handler edit.
    """
    _ = now_utc or datetime.now(timezone.utc)

    total = len(rows)
    if total == 0:
        # Empty window — emit only the zero-count so Grafana chart doesn't
        # gap out. No division-by-zero on the other metrics.
        return [Metric(name="IncidentCount", value=0.0, unit="Count", dimensions={})]

    ack_count = 0
    groq_count = 0
    mttr_deltas: list[float] = []

    for row in rows:
        # Ack + MTTR
        ingested = _parse_iso(row.get("ingestedAt"))
        acked = _parse_iso(row.get("acknowledgedAt"))
        if ingested and acked:
            delta = (acked - ingested).total_seconds()
            if delta >= 0:  # skip negative (clock skew) silently
                ack_count += 1
                mttr_deltas.append(delta)

        # LLM success
        if str(row.get("rcaSource") or "none") == "groq":
            groq_count += 1

    metrics: list[Metric] = [
        Metric("IncidentCount", float(total), "Count", {}),
        Metric("AckedIncidentCount", float(ack_count), "Count", {}),
        Metric("AckRatePercent", (ack_count / total) * 100.0, "Percent", {}),
        Metric("LLMSuccessRatePercent", (groq_count / total) * 100.0, "Percent", {}),
    ]
    if mttr_deltas:
        avg = sum(mttr_deltas) / len(mttr_deltas)
        metrics.append(Metric("MTTRSecondsAvg", avg, "Seconds", {}))

    return metrics
