# Module 3 — crashy-app + Helm chart + ECR

> **Build-time runbook.** Written while this module was built, before the first real AWS run. For the tested steps, use [`docs/INSTALL.md`](../INSTALL.md); where the two differ, INSTALL wins.

**Time:** ~15 min (Terraform apply + build + push + helm install).
**Prerequisite:** Modules 0-2 complete (`kubectl get nodes` shows 2 K3s nodes Ready).
**What it delivers:** a running FastAPI microservice on the K3s cluster with pod anti-affinity across zones, and a private ECR repo that hosts its container image. From Module 4 onwards the SmartOps controller will watch this app's failure events.
**Cost impact:** $0 in free tier. ECR storage < 200 MB; K3s pod runs on existing t3.micros.

<!-- toc -->
- [Overview](#overview)
- [What Module 3 adds](#what-module-3-adds)
- [Step-by-step](#step-by-step)
- [Verify anti-affinity works](#verify-anti-affinity-works)
- [Exercise the failure endpoints](#exercise-the-failure-endpoints)
- [Toggling / cleanup](#toggling--cleanup)
- [Troubleshooting](#troubleshooting)
- [What Module 3 delivered — checklist](#what-module-3-delivered--checklist)
<!-- /toc -->

---

## Overview

```
                    ┌─────────────────────┐
                    │  Your workstation   │
                    │  docker build       │
                    │  make docker-push   │
                    └──────────┬──────────┘
                               │  push  :latest, :git-<sha>
                               ▼
        ┌──────────────────────────────────────────┐
        │  ECR: smartops/crashy-app                │
        │  scan-on-push, lifecycle: keep 20 + 10   │
        └──────────────────────┬───────────────────┘
                               │  pull (via node IAM
                               │        AmazonEC2ContainerRegistryReadOnly)
              ┌────────────────┴─────────────────┐
              ▼                                  ▼
  ┌─────────────────────┐              ┌─────────────────────┐
  │  K3s server (AZ-a)  │              │  K3s agent  (AZ-b)  │
  │  ┌───────────────┐  │              │  ┌───────────────┐  │
  │  │ crashy-app #1 │  │              │  │ crashy-app #2 │  │
  │  └───────────────┘  │              │  └───────────────┘  │
  └─────────────────────┘              └─────────────────────┘
          topology.kubernetes.io/zone=ap-south-1a / ap-south-1b
          (labels set by cloud-init from IMDS — Module 2.1 audit fix)

  requiredDuringSchedulingIgnoredDuringExecution
    ↳ no more than one pod per zone
```

Every response the app returns carries `X-Pod-Name`, `X-Pod-Node`, `X-Pod-Zone` headers, so a curl loop against the Service round-robin's the two replicas and you literally see the spread.

---

## What Module 3 adds

### Code (`apps/crashy-app/`)
| File | Purpose |
|---|---|
| `pyproject.toml` | Poetry-managed Python 3.12 project — FastAPI, uvicorn, pydantic; dev deps: pytest, ruff, mypy |
| `src/crashy/main.py` | FastAPI app. 7 endpoints: `/`, `/healthz`, `/ready`, `/crash`, `/oom`, `/500`, `/slow` |
| `src/crashy/__main__.py` | Entry point for `python -m crashy` — runs uvicorn |
| `tests/test_main.py` | Smoke tests for non-destructive endpoints |
| `Dockerfile` | Multi-stage build. Runtime: `python:3.12-slim` + tini, non-root UID 65534, `readOnlyRootFilesystem` compatible |
| `.dockerignore` | Excludes tests, caches, venvs from image context |
| `README.md` | Per-app README (endpoint table, local dev, env vars) |

### Infrastructure (`infra/`)
| File | Purpose |
|---|---|
| `modules/ecr/{main,variables,outputs}.tf` | Reusable ECR module — creates N repos with scan-on-push + lifecycle policy (keep 20 tagged + 10 untagged) |
| `envs/dev/variables.tf` (edited) | New: `ecr_repository_names` (default `["smartops/crashy-app"]`) |
| `envs/dev/main.tf` (edited) | New: `module "ecr"` wired; `module "iam"` now passes `attach_ecr_read_only = true` |
| `envs/dev/outputs.tf` (edited) | New: `ecr_repository_urls`, `ecr_registry_url` |
| `modules/iam/{variables,main}.tf` (edited) | New: `attach_ecr_read_only` toggle → attaches AWS-managed `AmazonEC2ContainerRegistryReadOnly` policy to node role |

### Helm chart (`helm/crashy-app/`)
| File | Purpose |
|---|---|
| `Chart.yaml` | Chart v0.1.0, app v0.1.0, kubeVersion ≥ 1.28 |
| `values.yaml` | Image, replicas (2), affinity mode (required/preferred/none), security context, resources, probes, service, SA, env |
| `templates/_helpers.tpl` | Standard name/fullname/labels helpers |
| `templates/deployment.yaml` | Deployment with **hard pod anti-affinity on `topology.kubernetes.io/zone`**, downward-API env vars for `POD_NAME`/`NODE`/`ZONE`, checksum/values annotation to force rolling restart on values changes |
| `templates/service.yaml` | ClusterIP Service on port 80 → container 8000 |
| `templates/serviceaccount.yaml` | Dedicated SA (empty annotations today; IRSA added in Module 4) |
| `templates/NOTES.txt` | Post-install hints (kubectl commands, curl commands, port-forward) |
| `.helmignore` | Standard exclusions |

### Ops
| File | Purpose |
|---|---|
| `Makefile` (edited) | New targets: `ecr-login`, `docker-build-crashy`, `docker-push-crashy`, `helm-install-crashy`, `chaos-*`, `chaos-spread` |
| `scripts/chaos.sh` (rewritten) | Uses new label selectors + real endpoints. Sub-commands: `crash`, `oom`, `error`, `slow --ms N`, `info`, `spread` |

---

## Step-by-step

Assumes you've already run Modules 0-2 and `kubectl get nodes` shows 2 nodes Ready.

### 3.1 Apply the new Terraform (creates ECR + attaches ECR read-only IAM)

```bash
make tf-plan       # review — should show ~4 new resources (ECR repo, lifecycle, IAM attachment)
make tf-apply
```

Verify:
```bash
cd infra/envs/dev && terraform output ecr_repository_urls
# → { "smartops/crashy-app" = "<acct>.dkr.ecr.ap-south-1.amazonaws.com/smartops/crashy-app" }
```

### 3.2 Build + push the container image

```bash
make docker-build-crashy    # local build, tags: :latest + :git-<sha>
make docker-push-crashy     # ecr-login → tag → push (both tags)
```

`make docker-push-crashy` depends on `ecr-login` and `docker-build-crashy` — running it directly is enough.

Verify the image landed:
```bash
aws ecr describe-images --repository-name smartops/crashy-app \
  --query 'imageDetails[].{tags:imageTags,pushed:imagePushedAt,size:imageSizeInBytes}' \
  --output table
```

You should see the two tags (`latest` + `git-<sha>`) and a scan result appear within ~60s.

### 3.3 Install the Helm chart

```bash
# Ensure the SSM tunnel to K3s API is still open (from Module 2).
# In another terminal:
#   eval "$(cd infra/envs/dev && terraform output -raw kube_api_tunnel_cmd)"

make helm-install-crashy
# → reads the ECR URL from tf output, injects it via --set image.repository=<url>
```

Watch the two pods land:
```bash
export KUBECONFIG=~/.kube/config-smartops
kubectl -n demo get pods -l app.kubernetes.io/instance=app -w
```

Expected: `app-crashy-app-<hash>-<xxxxx>` × 2, one on each K3s node, both `Running` + `Ready` within ~40 s (image pull + 3 s readiness gate).

### 3.4 Sanity-check the endpoints

```bash
kubectl -n demo port-forward svc/app-crashy-app 18080:80 &
sleep 1
for i in 1 2 3 4; do
  curl -s http://localhost:18080/ | jq
done
# → uptime + pod/node/zone identity per request; you'll see it round-robin
#   between pods on ap-south-1a and ap-south-1b
```

`kill %1` to stop the port-forward when done.

---

## Verify anti-affinity works

The whole point of Module 2's topology-label fix is that pod anti-affinity spreads the two replicas across AZs. Confirm:

```bash
make chaos-info    # human-readable pod / node / zone table
make chaos-spread  # exits 0 with a green tick if spread across ≥ 2 nodes
```

Expected output from `chaos-spread`:
```
==> pods for release 'app' in namespace 'demo':
NAME                              NODE           ZONE   PHASE     READY
app-crashy-app-7c8b6f9d54-abc12   ip-10-0-1-11   ...    Running   true
app-crashy-app-7c8b6f9d54-def34   ip-10-0-2-22   ...    Running   true
✔ pods are spread across 2 distinct nodes
```

If you see "pods are on 1 node(s) only", one of these is true:
- `enable_agent = false` in tfvars → single-node cluster (fix: re-enable + `tf-apply`)
- `affinityMode: preferred` in values.yaml → anti-affinity was best-effort (fix: switch to `required`)
- The node lost the `topology.kubernetes.io/zone` label → check `kubectl get nodes -L topology.kubernetes.io/zone`

---

## Exercise the failure endpoints

Each of these triggers exactly one of the four failure signatures Module 4 will detect:

```bash
make chaos-crash    # /crash → os._exit(1) → CrashLoopBackOff on repeat
make chaos-oom      # /oom → allocate until OOMKilled (limit is 128Mi)
make chaos-error    # /500 → app-level HTTP error (pod stays healthy)
make chaos-slow     # /slow?ms=5000 → latency injection
```

Watch what happens:
```bash
kubectl -n demo get pods -l app.kubernetes.io/instance=app -w
kubectl -n demo describe pod <name>            # see LastState.Terminated + Reason
kubectl -n demo logs <name> --previous          # see the crash log line
kubectl -n demo get events --sort-by=.lastTimestamp | tail -20
```

**Recovery:** with `replicaCount=2` on 2 nodes, killing one pod leaves the Service healthy; kubelet restarts the crashed pod in ~5 s. This is the exact scenario Module 4's controller catches and reports on.

---

## Toggling / cleanup

**Just remove the Helm release, keep infra:**
```bash
KUBECONFIG=~/.kube/config-smartops helm uninstall app -n demo
```

**Nuke the image, keep the repo (dev iteration):**
```bash
aws ecr batch-delete-image --repository-name smartops/crashy-app \
  --image-ids imageTag=latest imageTag=git-<sha>
```

**End of session:**
```bash
make eod   # helm uninstall + terraform destroy (destroys ECR repos too — see below)
```

Note: `terraform destroy` will delete the ECR repos because `force_delete = true` in the module. This is intentional — the repos are re-created next `make up`, and images are cheap to rebuild. If you want images to survive teardown, set `force_delete = false` in `infra/modules/ecr/main.tf` and manually empty them before `make eod`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `make helm-install-crashy` → "ecr_repository_urls output missing" | `terraform apply` didn't include Module 3 | `make tf-apply` (should show ~4 new resources on plan) |
| `make docker-push-crashy` → `denied: not authorized` | `ecr-login` used a different profile than expected | `aws sts get-caller-identity` — should show `smartops-cli`. `export AWS_PROFILE=smartops` |
| Pods stuck `ImagePullBackOff` | Node IAM missing ECR permission — Module 3 sets `attach_ecr_read_only=true`, but the change hasn't been applied | `make tf-apply` and wait ~30s for the cached IAM decision to propagate. Then `kubectl -n demo delete pod -l app.kubernetes.io/instance=app` to force a fresh pull |
| Pods stuck `Pending` with "0/2 nodes are available: 2 node(s) didn't match pod anti-affinity rules" | Only one AZ has a Ready node OR both nodes are in the same AZ | `kubectl get nodes -L topology.kubernetes.io/zone` — must show ≥ 2 distinct zones. If missing labels, cloud-init failed → re-check `infra/modules/k3s/cloud-init.yaml.tftpl` |
| Pods start then immediately `CrashLoopBackOff` (unexpectedly) | Container can't bind to port 8000 OR `readOnlyRootFilesystem` broke something | `kubectl -n demo logs <pod> --previous`. If it's a "read-only file system" write, mount an `emptyDir` at that path in `values.yaml` (we already do this for `/tmp`) |
| `/oom` returns 200 instead of getting OOMKilled | `resources.limits.memory` was raised above 200Mi | Restore to 128Mi in `values.yaml` |
| `chaos-spread` says "pods on 1 node(s)" but tf output shows 2 nodes | Chart was installed with `--set affinityMode=preferred` at some point | `make helm-install-crashy` (which does not pass affinityMode → chart default of `required` kicks in) |
| Anti-affinity fires but you want to force both pods on one node for testing | Override at install time | `helm upgrade app helm/crashy-app -n demo --set affinityMode=none` |

---

## What Module 3 delivered — checklist

Before pushing:
- [x] `apps/crashy-app/pyproject.toml`, `src/crashy/{__init__,__main__,main}.py`, `tests/test_main.py`
- [x] `apps/crashy-app/Dockerfile`, `.dockerignore`, `README.md`
- [x] `infra/modules/ecr/{main,variables,outputs}.tf`
- [x] `infra/modules/iam/*` — added `attach_ecr_read_only` toggle
- [x] `infra/envs/dev/{main,variables,outputs}.tf` — wired ECR module, exposed URL outputs
- [x] `helm/crashy-app/Chart.yaml`, `values.yaml`, `templates/{_helpers.tpl,deployment.yaml,service.yaml,serviceaccount.yaml,NOTES.txt}`, `.helmignore`
- [x] `Makefile` — targets: `ecr-login`, `docker-build-crashy`, `docker-push-crashy`, `helm-install-crashy`, `chaos-{crash,oom,error,slow,info,spread}`
- [x] `scripts/chaos.sh` — rewritten to use new selectors + real endpoints
- [x] This runbook

**Commit message:** `feat(module-3): crashy-app + Helm chart + ECR repo`

**Next:** [Module 4 — K8s controller (watches pods, publishes to EventBridge, IRSA)](./04-controller.md) *(coming)*
