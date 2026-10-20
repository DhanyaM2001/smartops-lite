# crashy-app

Deliberately-failing FastAPI microservice used by [SmartOps-Lite](../../README.md) to exercise the Kubernetes incident-triage pipeline.

## Endpoints

| Path | Behavior | Purpose |
|---|---|---|
| `GET /` | Returns app + pod identity | Sanity ping, verifies pod anti-affinity spread |
| `GET /healthz` | Always 200 | Kubelet liveness probe |
| `GET /ready` | 503 for first `READY_AFTER_SECONDS` (default 3), then 200 | Kubelet readiness probe |
| `GET /crash` | `os._exit(1)` | Triggers `CrashLoopBackOff` after repeated hits |
| `GET /oom` | Allocates until OOMKilled | Triggers `OOMKilled` (container memory limit is 128 MiB) |
| `GET /500` | Raises `HTTPException(500)` | Application-level error (logged, no restart) |
| `GET /slow?ms=N` | Sleeps N milliseconds (0–60 000) | Latency injection |

Every response includes headers `X-Pod-Name`, `X-Pod-Node`, `X-Pod-Zone` so you can see which replica served the request — useful when confirming anti-affinity actually spread the pods across AZs.

## Local dev

```bash
cd apps/crashy-app
poetry install
poetry run uvicorn crashy.main:app --reload
# → http://localhost:8000/docs   (Swagger UI)
```

Run tests:
```bash
poetry run pytest
poetry run ruff check .
poetry run mypy src
```

## Container build (root Makefile is the canonical entry point)

```bash
# From repo root
make docker-build-crashy      # docker build -t crashy-app:dev
make docker-push-crashy       # tags + pushes to ECR (needs make ecr-login first)
```

## Runtime env vars

| Var | Default | Purpose |
|---|---|---|
| `PORT` | `8000` | Listen port |
| `HOST` | `0.0.0.0` | Bind address |
| `LOG_LEVEL` | `info` | uvicorn + app log level |
| `READY_AFTER_SECONDS` | `3` | Grace period before `/ready` returns 200 |
| `POD_NAME` | hostname | Value returned in `X-Pod-Name` header |
| `POD_NODE` | `unknown` | Value returned in `X-Pod-Node` header |
| `POD_ZONE` | `unknown` | Value returned in `X-Pod-Zone` header — currently always `unknown` (see note below) |

`POD_NAME` and `POD_NODE` are populated by the Helm chart's Downward-API `env:` block. **`POD_ZONE` is not**, because the Downward API reads *pod* labels and the `topology.kubernetes.io/zone` label is only present on *nodes* — using it as a `fieldRef` causes `CreateContainerConfigError` on every schedule. Use `make chaos-info` to observe the pod→node→zone map.
