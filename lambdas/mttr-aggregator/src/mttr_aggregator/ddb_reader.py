"""DynamoDB scan → list of unmarshalled dicts.

We scan (not query) because the demo table has O(hundreds) of rows and we
want a full-window view without secondary indexes. If the demo scaled to
O(millions), we'd add a GSI on `ingestedAt` and switch to query.

The reader is deliberately dumb: pagination + attribute-value unmarshalling,
nothing else. Filtering by window happens in Python (aggregator side) so
we keep the SDK contract narrow and easy to mock.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Any

log = logging.getLogger(__name__)


def _unmarshall(item: dict[str, dict[str, Any]]) -> dict[str, Any]:
    """Reverse the persistence._marshall shape. Only covers the AV types we
    write (S, N, BOOL, NULL, M, L).
    """
    out: dict[str, Any] = {}
    for k, av in item.items():
        out[k] = _av_to_python(av)
    return out


def _av_to_python(av: dict[str, Any]) -> Any:
    if not av:
        return None
    if "NULL" in av:
        return None
    if "S" in av:
        return av["S"]
    if "N" in av:
        s = av["N"]
        return int(s) if "." not in s else float(s)
    if "BOOL" in av:
        return bool(av["BOOL"])
    if "M" in av:
        return {k: _av_to_python(v) for k, v in av["M"].items()}
    if "L" in av:
        return [_av_to_python(v) for v in av["L"]]
    return None


def scan_recent(
    *,
    table_name: str,
    ddb_client,
    window_minutes: int,
    now_utc: datetime | None = None,
) -> list[dict[str, Any]]:
    """Scan the table and return rows where `ingestedAt` >= (now - window).

    Rows with a missing/unparseable `ingestedAt` are dropped — they don't
    belong to any recognizable time window.
    """
    now = now_utc or datetime.now(timezone.utc)
    cutoff = now - timedelta(minutes=window_minutes)
    cutoff_iso = cutoff.isoformat(timespec="seconds").replace("+00:00", "Z")

    rows: list[dict[str, Any]] = []
    kwargs: dict[str, Any] = {"TableName": table_name}
    while True:
        resp = ddb_client.scan(**kwargs)
        for raw in resp.get("Items", []):
            row = _unmarshall(raw)
            ingested = row.get("ingestedAt")
            # Lexicographic compare works for RFC3339 UTC strings.
            if ingested and ingested >= cutoff_iso:
                rows.append(row)
        if "LastEvaluatedKey" in resp:
            kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]
        else:
            break

    log.info(
        "ddb scan complete",
        extra={
            "table": table_name,
            "window_minutes": window_minutes,
            "cutoff_iso": cutoff_iso,
            "matched": len(rows),
        },
    )
    return rows
