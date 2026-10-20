# Module 4 — smartops-controller + EventBridge

> **Build-time runbook.** Written while this module was built, before the first real AWS run. For the tested steps, use [`docs/INSTALL.md`](../INSTALL.md); where the two differ, INSTALL wins.

> The first custom software running IN the cluster. It closes the loop from "kubernetes noticed a pod problem" to "an event landed on our AWS bus that Module 5's Lambda can consume".

## What ships in this module

| Artifact | Purpose |
|---|---|
| `controller/` (Python package) | Kubernetes watcher that turns Pod events into structured incidents |
| `helm/smartops-controller/` | Helm chart: Deployment + Service + ServiceAccount + ClusterRole + ClusterRoleBinding |
| `infra/modules/eventbridge/` | Reusable Terraform module — custom EventBridge bus + optional archive |
| `attach_controller_policy` toggle on `infra/modules/iam` | Adds `events:PutEvents` on the bus ARN only, to the node role |
| New env-root wiring in `infra/envs/dev/{main,variables,outputs}.tf` | Instantiates the bus + exposes `event_bus_name` / `event_bus_arn` outputs |
| Makefile targets | `docker-build-controller`, `docker-push-controller`, `helm-install-controller` |
| Extended `scripts/verify.sh` | Checks bus exists + controller Deployment Ready + `/healthz` responds |
| `local-up.sh` integration | Local kind path deploys the controller in `DRY_RUN=true` mode automatically |

## Architecture

```
     ┌───────────────────────────────────────────────────────┐
     │  K3s cluster (EC2 in AZ-a and AZ-b)                    │
     │                                                        │
     │  ┌──────────────┐    watch Pod events    ┌──────────┐  │
     │  │ K8s API      │◀────────────────────── │ controller│ │
     │  │ Server       │                        │  Pod      │ │
     │  └──────────────┘                        │  (1 rep)  │ │
     │                                          └────┬─────┘  │
     │                                               │        │
     │  ┌──────────────┐   crashy-app fails          │        │
     │  │  crashy-app  │◀── (Module 3 image)         │        │
     │  │  Pod × 2     │                             │        │
     │  └──────────────┘                             │        │
     │                                               │        │
     │  Every EC2 node has an IAM role with          │        │
     │  events:PutEvents on ONE bus ARN only.        │        │
     │  The controller pod inherits creds via        │        │
     │  the IMDS credential chain.                   │        │
     │                                               │        │
     └───────────────────────────────────────────────┼────────┘
                                                     │
                                                     │  boto3 → PutEvents
                                                     ▼
                                    ┌───────────────────────────────┐
                                    │  AWS EventBridge              │
                                    │  Custom bus: smartops-dev      │
                                    │  DetailType: IncidentDetected  │
                                    └───────────────┬───────────────┘
                                                    │
                                                    ▼
                                           (Module 5 — RCA Lambda)
```

## The IRSA-vs-Node-IAM decision

**We chose node IAM with a least-privilege inline policy.** The rejected alternative was full IRSA (IAM Roles for Service Accounts) on K3s.

### What each looks like

**Node IAM (what we did):**
- The EC2 IAM role (`smartops-lite-node-role`) has an inline policy: `events:PutEvents` on `arn:aws:events:...:event-bus/smartops-dev` — one action, one resource.
- The controller Pod runs on a node whose EC2 metadata service (IMDS) serves temporary credentials tied to that role. The AWS SDK's default credential provider chain picks these up automatically.
- No per-Pod identity. Every pod on the node shares the node's permissions.

**IRSA (rejected for Module 4):**
- Reconfigure K3s so ServiceAccount tokens are signed by a stable key and the issuer URL is a public HTTPS endpoint (typically an S3 bucket serving OIDC discovery + JWKS).
- Create an IAM OIDC provider in AWS pointing at that S3 URL.
- Create a per-Pod IAM role whose trust policy uses `sts:AssumeRoleWithWebIdentity` bound to `system:serviceaccount:smartops:controller`.
- The AWS SDK exchanges the Pod's projected ServiceAccount token for temporary AWS credentials, one Pod at a time.

### Why node IAM won for the first pass

| | Node IAM | IRSA on K3s |
|---|---|---|
| **Setup complexity** | Add one inline policy (~20 lines TF) | Reconfigure kubelet, publish OIDC docs to public S3, create OIDC provider, per-Pod trust policy (~200 lines TF + K3s systemd changes) |
| **Time to first working demo** | Immediate | 1-2 evenings of first-time debugging (JWT audience, thumbprint, K3s issuer flag propagation) |
| **Permission blast radius** | Every Pod on the node shares the policy | Per-Pod isolation |
| **Portfolio story** | "least-privilege node role" | "full AWS-native IRSA on a self-managed cluster" |
| **Permanent infra footprint** | 0 new resources | Public S3 bucket + IAM OIDC provider (permanent, ~$0.001/mo) |
| **Cost** | $0 | $0 |

The blast-radius argument is weaker than it looks in our case: only two workloads run in this cluster (`crashy-app` and `smartops-controller`), and `crashy-app` never calls AWS, so today the policy is effectively per-Pod anyway.

### The upgrade path (Module 4.1, if we do it)

The controller code is **credential-source-agnostic** — `boto3` picks whatever the credential chain finds first. Migrating to IRSA later is:
1. Add the `.serviceAccount.annotations["eks.amazonaws.com/role-arn"]` value in `helm/smartops-controller/values.yaml` (the line is already present, empty)
2. Create the IRSA infra in a new Terraform module
3. Remove `attach_controller_policy=true` from the env root (so the node role loses `events:PutEvents`)
4. Roll the controller Pod

No Python changes.

## Detection logic

`detector.detect(pod)` is a pure function — takes a Pod object, returns 0+ `Incident` dataclasses. This is the CORE testable piece. The watcher just calls it in a loop.

**Reasons that trigger an incident:**

| Source field | Values |
|---|---|
| `status.containerStatuses[*].state.waiting.reason` | `CrashLoopBackOff`, `ImagePullBackOff`, `ErrImagePull`, `ErrImageNeverPull`, `CreateContainerConfigError`, `CreateContainerError`, `RunContainerError` |
| `status.containerStatuses[*].lastState.terminated.reason` | `OOMKilled`, `Error` (only when `exit_code != 0`) |
| `status.phase` | `Failed` |

**Deduplication.** The watcher owns an LRU set keyed on `(namespace, pod_name, container_name, reason)`. Same tuple → publish once. Cache capacity is `DEDUP_CACHE_SIZE` (default 4096, tunable). This is intentionally in-memory only; on a controller restart we may re-publish everything the API server still shows as `CrashLoopBackOff`, which is FINE because Module 5's Lambda + Module 6's DDB write will be idempotent by `incidentId`.

**What we DON'T detect (yet):**
- Successful terminations (obviously)
- Node NotReady (belongs on a NodeWatcher, out of scope)
- PVC issues, quota rejections, PodSecurityPolicy failures (Module 5 Lambda can enrich from events API)

## Event payload

Published as one `PutEvents` entry per incident:

```json
{
  "Source": "smartops.controller",
  "DetailType": "IncidentDetected",
  "EventBusName": "smartops-dev",
  "Detail": {
    "schemaVersion": "1.0",
    "incidentId": "b48b9a2d-e46c-4c1a-9f26-1d2d78d15f39",
    "namespace": "demo",
    "podName": "app-crashy-app-6b8c-xyz",
    "podUid": "c1e0-...",
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

Downstream (Module 5) writes this straight to DynamoDB — the schema is intended to be stable across modules. If we need to change it, bump `schemaVersion` and add a translator on the Lambda side.

## Local demo (no AWS needed)

The kind-based local path automatically deploys the controller in `DRY_RUN=true` mode — every "publish" becomes a JSON log line instead of a boto3 call.

```bash
make local-up                                                # kind + crashy-app + controller (dry-run)
KUBECONFIG=~/.kube/config-smartops-local \
  kubectl -n smartops logs -l app.kubernetes.io/name=smartops-controller -f
# ...in another terminal:
make chaos-crash                                             # trigger CrashLoopBackOff on crashy-app
# Watch controller log — should show `"message": "dry-run publish"` events.
```

## Real-AWS demo

```bash
make tf-apply                              # creates the bus + adds controller policy to node role
make docker-push-controller                # build + push controller image to ECR
make helm-install-controller               # installs into namespace `smartops`
make chaos-crash                           # trigger a real incident

# Verify the event landed:
aws --profile smartops --region ap-south-1 events describe-event-bus --name smartops-dev

# Metrics:
kubectl -n smartops port-forward svc/ctrl-smartops-controller 8081:80
curl -s localhost:8081/metrics | jq
# → {"events_seen":247, "incidents_published":3, "incidents_deduped":41, ...}
```

Full CLI reference lives in [`docs/REFERENCE.md`](../REFERENCE.md).

## Testing

Two test files:

- `controller/tests/test_detector.py` — 13 unit tests against the pure detection logic. No K8s, no AWS, no I/O. Runs in <1 s.
- `controller/tests/test_publisher.py` — uses `moto` to mock EventBridge for the real publisher; verifies the dry-run publisher never calls AWS. Runs in <2 s.

```bash
cd controller
poetry install --with dev
poetry run pytest -v
```

## Known limitations (deferred to later modules)

1. **Single replica.** No leader election. If we ever run 2+, we'd double-publish (idempotent downstream, but 2× AWS API calls). Module 12 can add a Lease-based leader if the load ever warrants it.
2. **Node IAM sharing.** See the IRSA discussion above. Not a real risk today (2 workloads).
3. **No exponential backoff on publish failures.** The K8s watch will re-deliver the same pod event when it reconnects, so we get retry-for-free. If EventBridge starts throttling, we'd want a proper retry queue here.
4. **Zone label read from pod, not node.** `detector.detect()` reads `topology.kubernetes.io/zone` from the pod's labels — meaning the workload must copy it in via downward API. `crashy-app` doesn't; we fall back to `null` and let Module 5 enrich from the Node object.
