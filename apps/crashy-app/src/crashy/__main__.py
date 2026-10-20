"""Entry point for `python -m crashy` and the poetry console script.

Runs uvicorn against crashy.main:app on the port from $PORT (default 8000).
"""

from __future__ import annotations

import os

import uvicorn


def main() -> None:
    port = int(os.getenv("PORT", "8000"))
    host = os.getenv("HOST", "0.0.0.0")  # noqa: S104 — bind-all is required inside a pod
    uvicorn.run(
        "crashy.main:app",
        host=host,
        port=port,
        log_level=os.getenv("LOG_LEVEL", "info").lower(),
        access_log=True,
    )


if __name__ == "__main__":
    main()
