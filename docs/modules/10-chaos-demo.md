# Module 10 — Chaos runner + polished demo orchestration

> **Build-time runbook.** Written while this module was built, before the first real AWS run. For the tested steps, use [`docs/INSTALL.md`](../INSTALL.md); where the two differ, INSTALL wins. The recording used the manual steps in INSTALL §6 rather than `make demo`, and `make up` isn't a one-shot on a fresh deploy (INSTALL §5 has the order).

> **Scope.** Small polish module whose whole job is to make Module 11's Loom recording clean. Sharpens `scripts/chaos.sh` (real zone reporting), rewrites `scripts/demo.sh` (pre-flight + end-to-end verification + rehearsal/reset modes), adds `scripts/pre-demo-check.sh` (one-shot readiness check).
>
> **Goal.** From a clean `make up` state, one command (`make demo`) produces a repeatable ~90-second narrative that walks through the whole pipeline and ends with a green metrics screenshot ready for the video.
>
> **Cost.** $0/mo. Pure scripting; no new AWS resources.

---

## 1. What was wrong with the pre-Module-10 versions

### `scripts/chaos.sh`

- `info` printed `ZONE:.spec.nodeSelector` — but pods have empty `nodeSelector` (`{}`), so the column was always blank. **Actual zone lives on the node**, via the `topology.kubernetes.io/zone` label (set by Module 2.1's IMDS cloud-init). Fixed by pod→node join in awk.
- `spread` counted **nodes**, not zones. On a mis-labelled cluster this would report "spread across 2 nodes" even when both were in the same AZ. Now counts distinct `topology.kubernetes.io/zone` values.

### `scripts/demo.sh`

- Was optimized for a Module-2/3 story: 60 seconds, pod restart demo, `<cluster-ip>:3000` for a self-hosted Grafana that never existed.
- Referenced auto-remediation (`.spec.template.spec.containers[0].resources`) but Module 7.0 is **ack-only** — nothing patches the deployment. Misleading.
- No pre-flight check — if the SSM tunnel was closed, `kubectl` would hang for 30+ seconds mid-recording.
- No verification that the pipeline actually did anything — Slack card, DDB row, CloudWatch metric were all "trust me".
- No `--reset` mode — after a run, the cluster had a dead pod; you needed 3-4 manual `helm` commands to reset for take 2.

---

## 2. What Module 10 ships

### 2.1 `scripts/chaos.sh` — fixed zone reporting

```
POD                                    NODE                       ZONE       PHASE    READY
---                                    ----                       ----       -----    -----
app-crashy-app-6d4d7cbdd6-9jkfz         ip-10-0-1-42.ap-south-1    ap-south-1a Running true
app-crashy-app-6d4d7cbdd6-vxq82         ip-10-0-2-19.ap-south-1    ap-south-1b Running true
```

`spread` now differentiates the three failure modes:

| Nodes | Zones | Verdict                                            |
|-------|-------|----------------------------------------------------|
| 1     | 1     | ! single-node cluster or `affinityMode: preferred` |
| 2+    | 1     | ! nodes lack `topology.kubernetes.io/zone` labels  |
| 2+    | 2+    | ✔ anti-affinity working                           |

### 2.2 `scripts/demo.sh` — end-to-end narrative

Timeline (each `[MM:SS]` is a banner in the script):

```
[00:00] SmartOps-Lite — end-to-end demo
[00:03] baseline — 2 replicas spread across 2 zones      chaos.sh spread
[00:10] triggering CrashLoopBackOff on one replica       chaos.sh crash
[00:20] watching pod state (10 s window)                 kubectl get pods -w
[00:35] Slack ⇒ #smartops-alerts should now show card    (10 s pause for LLM + Slack)
[00:45] verify DDB — last incident persisted             aws dynamodb scan
[00:55] force-refresh dashboard metrics                  aws lambda invoke $mttr_fn
[01:05] CloudWatch metrics (5 series Grafana reads)      aws cloudwatch list-metrics
[01:15] Grafana dashboard                                (URL from dashboards/grafana/)
[01:25] cost so far this month                           aws ce get-cost-and-usage
[01:30] done.
```

**Three modes:**

- `bash scripts/demo.sh` — full run (default).
- `bash scripts/demo.sh --dry-run` — banners fire in order but every AWS/cluster mutation is skipped. Useful to rehearse the narration before recording.
- `bash scripts/demo.sh --reset` — `kubectl rollout restart` + wait for Ready. Runs standalone in ~30 s between takes.
- `bash scripts/demo.sh --skip-preflight` — skip the pre-flight block (for CI, where secrets aren't in SSM).

### 2.3 `scripts/pre-demo-check.sh` — one-shot readiness

Read-only. Verifies:

1. **Toolchain** — `kubectl`, `aws`, `terraform`, `helm`, `curl`, `jq`.
2. **AWS identity** — `aws sts get-caller-identity` succeeds; region matches.
3. **Cluster** — `kubectl version` succeeds via `~/.kube/config-smartops`; at least 1 Ready node.
4. **Deployment** — `<release>-crashy-app` exists in `<namespace>`, prints ready-replicas count.
5. **Secrets** — all three SSM SecureStrings present (`slack_webhook`, `groq_api_key`, `slack_signing_secret`).
6. **Terraform outputs** — the four names the demo will read via `terraform output -raw`.
7. **CloudWatch metrics populated** — warns (not errors) if the SmartOps namespace is empty; run `make invoke-mttr` before recording.

Exit codes: `0` = go record, `1` = hard blocker, `2` = warnings only.

### 2.4 New Makefile targets (`§2.10`)

```
make demo               ~90-second end-to-end demo
make demo-dry-run       rehearsal mode (no cluster/AWS mutations)
make demo-reset         roll crashy-app back to healthy between takes
make pre-demo-check     one-shot readiness check
```

---

## 3. Design decisions worth calling out

### 3.1 Why pre-flight is default-on

Loom takes cost real minutes to record. A failed take because the SSM tunnel was closed 30 seconds earlier is expensive. Pre-flight is default-on with `--skip-preflight` as the escape hatch. CI, which knows there won't be any SSM secrets, uses the flag; humans running `make demo` never think about it.

### 3.2 Why `--dry-run` shows the banners

The banners ARE the narration script. During rehearsal we want to time the story ("keep talking here for 4 seconds") without waiting for real Slack deliveries. `--dry-run` skips the `sleep` calls too (via `pause() { $DRY_RUN && return 0; ... }`), so a rehearsal fires in a few seconds.

### 3.3 Why `--reset` uses `rollout restart`, not `helm upgrade`

`helm upgrade` would work but rebuilds every Service/ServiceAccount/PVC. `kubectl rollout restart` just cycles the pods — 15-30 s instead of 60+, and doesn't touch the network layer. Safe because a fresh replica always starts healthy (nothing in the ConfigMap/env selects the failure endpoints on startup).

### 3.4 Why we force-invoke the MTTR aggregator during the demo

The aggregator's schedule is `rate(5 minutes)`. In a 90-second recording, waiting for a real tick would blow the timing. The `[00:55]` block does a synthetic invoke with `{"time": "<now>"}` so the metrics land in CloudWatch immediately, and the Grafana screenshot at `[01:15]` is populated in the same recording.

### 3.5 Why we don't tail Slack

Slack has no CLI-readable "last message" endpoint. Any check would need a Slack API token with read scope + a channel ID + rate limiting. The `[00:35]` banner instead just describes what Slack is showing, and the operator visually confirms in the Slack window during the Loom recording. Adds no dependency; keeps the recording story anchored in what's on-screen.

---

## 4. Loom recording workflow (feeds Module 11)

```bash
# Once, before recording
make up                       # brings up the K3s cluster (Modules 1+2)
make helm-install             # Modules 3+4
make put-secrets              # Modules 5+6
make put-signing-secret       # Module 7
make tf-apply                 # ensures Module 9 aggregator + schedule exist
make invoke-mttr              # first synthetic tick so dashboard isn't blank
make pre-demo-check           # → all green?

# For each take
make demo-reset               # 30 s, restores to healthy
# … press Record on Loom …
make demo                     # 90 s narrated end-to-end
# … stop Record …
```

If `make demo` misfires (e.g. Groq quota exhausted → placeholder RCA), the recording is still usable — the pipeline itself doesn't degrade.

---

## 5. Change-log

| Date | Change |
|------|--------|
| 2026-08-26 | Initial ship: chaos.sh zone fix, demo.sh rewrite (pre-flight + dry-run + reset), pre-demo-check.sh, 4 new Makefile targets. |
