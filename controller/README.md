# smartops-controller

In-cluster Kubernetes controller for **SmartOps-Lite** (Module 4). Watches Pod events, detects failure states (CrashLoopBackOff, OOMKilled, ImagePullBackOff, etc.), and publishes structured incidents to an AWS EventBridge custom bus.

## What it does

1. `kubernetes.watch.Watch().stream(list_pod_for_all_namespaces)` — long-poll pod events cluster-wide (filtered by RBAC)
2. `detector.detect(pod)` — pure function: returns 0+ `Incident` objects
3. LRU-dedup on `(namespace, pod, container, reason)` so a hot-looping pod publishes once
4. `publisher.publish(inc)` — either `EventBridgePublisher` (real boto3 → PutEvents) or `DryRunPublisher` (logs to stdout, for local demos)

## Wire diagram

```
K8s API ──▶ PodWatcher ──▶ detector.detect() ──▶ dedup LRU ──▶ Publisher
                                                                 │
                                          ┌──────────────────────┴──────────┐
                                          ▼                                 ▼
                             (dry_run=false)                      (dry_run=true)
                             EventBridgePublisher                 DryRunPublisher
                             boto3 → PutEvents                    stdout / JSON logs
                                          │
                                          ▼
                             ┌──────────────────────────┐
                             │ AWS EventBridge          │
                             │ custom bus: smartops-dev │
                             └──────────────────────────┘
                                          │
                                          ▼
                             (Module 5 — RCA Lambda)
```

## Environment variables

| Var | Default | Meaning |
|---|---|---|
| `AWS_REGION` | `ap-south-1` | Region for the EventBridge client |
| `EVENT_BUS_NAME` | `smartops-dev` | Custom EventBridge bus name |
| `DRY_RUN` | `false` | If truthy: log to stdout, never call AWS |
| `WATCH_NAMESPACES` | *(empty = all)* | Comma-separated allowlist |
| `EXCLUDE_NAMESPACES` | `kube-system,kube-public,kube-node-lease,smartops` | Comma-separated denylist |
| `LOG_LEVEL` | `INFO` | Python log level |
| `RECONNECT_BACKOFF_SECONDS` | `3` | Wait before reconnecting the watch stream |
| `DEDUP_CACHE_SIZE` | `4096` | Max entries in the LRU dedup set |
| `HEALTH_PORT` | `8081` | Port for `/healthz`, `/ready`, `/metrics` |
| `POD_NAMESPACE` | `smartops` | Injected via downward API in the Helm chart |
| `NODE_NAME` | `unknown` | Injected via downward API |

## Endpoints (`HEALTH_PORT`)

- `GET /healthz` → 200 always
- `GET /ready` → 200 once the K8s watch stream has connected
- `GET /metrics` → JSON counters (events_seen, incidents_published, incidents_deduped, reconnects, publish_errors)

## Event schema

```json
{
  "Source": "smartops.controller",
  "DetailType": "IncidentDetected",
  "EventBusName": "smartops-dev",
  "Detail": {
    "schemaVersion": "1.0",
    "incidentId": "<uuid>",
    "namespace": "demo",
    "podName": "app-crashy-app-6b8c-xyz",
    "podUid": "<pod uid>",
    "containerName": "crashy",
    "reason": "CrashLoopBackOff",
    "restartCount": 5,
    "nodeName": "ip-10-0-1-42",
    "zone": "ap-south-1a",
    "timestamp": "2026-08-24T10:15:32Z",
    "message": "Back-off 5m0s restarting failed container",
    "exitCode": null,
    "labels": { "app.kubernetes.io/name": "crashy-app", ... }
  }
}
```

## Local dev

```bash
cd controller
poetry install --with dev
DRY_RUN=true poetry run smartops-controller
```

## Running tests

```bash
poetry run pytest -v
```

- `tests/test_detector.py` — pure unit tests on detection logic (no K8s, no AWS)
- `tests/test_publisher.py` — moto-mocked EventBridge for the real path + dry-run assertions

## Container

```bash
docker build -t smartops-controller:local .
docker run --rm -e DRY_RUN=true -p 8081:8081 smartops-controller:local
curl -s localhost:8081/healthz
```
