# syntax=docker/dockerfile:1.7
#
# smartops-controller — multi-stage build.
# Same shape as apps/crashy-app/Dockerfile (see that file for full commentary).
# Diff vs. crashy-app:
#   - Default port 8081 (health/metrics), not 8000
#   - Entrypoint: `python -m smartops_controller`
#   - Adds a HEALTHCHECK for local `docker run` sanity (K8s uses probes instead)

ARG PYTHON_VERSION=3.12
ARG APP_UID=65534
ARG APP_GID=65534

# -------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim AS builder
# -------------------------------------------------------------------------

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    POETRY_VERSION=1.8.3 \
    POETRY_VIRTUALENVS_CREATE=false \
    POETRY_NO_INTERACTION=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl build-essential \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir "poetry==${POETRY_VERSION}"

WORKDIR /build

COPY pyproject.toml ./
COPY poetry.lock* ./

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && poetry export --without dev --without-hashes --format requirements.txt --output /tmp/requirements.txt \
    && /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

COPY src ./src
COPY README.md ./
RUN /opt/venv/bin/pip install --no-cache-dir .

# -------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim AS runtime
# -------------------------------------------------------------------------

ARG APP_UID
ARG APP_GID

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    HEALTH_PORT=8081 \
    LOG_LEVEL=INFO

RUN apt-get update && apt-get install -y --no-install-recommends \
        tini ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv

USER ${APP_UID}:${APP_GID}
WORKDIR /app
EXPOSE 8081

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python", "-m", "smartops_controller"]

LABEL org.opencontainers.image.title="smartops-controller" \
      org.opencontainers.image.description="Watches K8s Pod events, publishes incidents to AWS EventBridge (Module 4 of SmartOps-Lite)." \
      org.opencontainers.image.source="https://github.com/dhanym/smartops-lite" \
      org.opencontainers.image.licenses="MIT"
