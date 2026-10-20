# syntax=docker/dockerfile:1.7

# =========================================================================
# crashy-app — multi-stage build
#   Stage 1 (builder) : install poetry, export a lockfile-derived requirements.txt,
#                       install deps into an isolated venv.
#   Stage 2 (runtime) : copy the venv + source into a minimal image.
#
# Design notes:
#   - python:3.12-slim (not distroless) so the runtime is easy to shell into
#     for debugging in early modules. We enforce non-root, read-only rootfs
#     from Kubernetes' securityContext instead — same net security posture.
#   - No poetry in the final image (saves ~40 MB).
#   - Non-root UID/GID 65534 (nobody) — matches K8s PodSecurityStandards "restricted".
#   - Final image size target: < 200 MB.
# =========================================================================

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

# Copy only files needed to resolve deps first — max cache reuse.
COPY pyproject.toml ./
# poetry.lock is optional at first build; include if present.
COPY poetry.lock* ./

# Install prod deps into a self-contained venv we'll copy to the runtime stage.
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && poetry export --without dev --without-hashes --format requirements.txt --output /tmp/requirements.txt \
    && /opt/venv/bin/pip install --no-cache-dir -r /tmp/requirements.txt

# Now copy the source and install the app itself (editable-off).
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
    PORT=8000 \
    HOST=0.0.0.0 \
    LOG_LEVEL=info

# Minimal runtime deps (tini for signal handling, ca-certs for HTTPS).
RUN apt-get update && apt-get install -y --no-install-recommends \
        tini ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv

# Drop privileges. Numeric UID (not name) so K8s' runAsNonRoot admission works.
USER ${APP_UID}:${APP_GID}

WORKDIR /app

EXPOSE 8000

# Tini as PID 1: reaps zombies, forwards SIGTERM correctly on graceful shutdown.
ENTRYPOINT ["/usr/bin/tini", "--"]

# uvicorn directly (not `python -m crashy`) so the process tree is 1 layer shallower.
CMD ["uvicorn", "crashy.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]

# OCI labels — recruiters + supply-chain scanners read these.
LABEL org.opencontainers.image.title="crashy-app" \
      org.opencontainers.image.description="Deliberately-failing FastAPI service for SmartOps-Lite E2E tests" \
      org.opencontainers.image.source="https://github.com/dhanym/smartops-lite" \
      org.opencontainers.image.licenses="MIT"
