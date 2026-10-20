# SmartOps-Lite — Project Reference (Encyclopedia)

> **What this file is.** The single source of truth for **every script, every
> Makefile target, every folder, every design choice** in the project. Updated
> at the end of every module.
>
> **When to read it.**
> - You forgot what a script does → §3
> - You want to know the exact command for X → §2
> - You're onboarding someone (or your future self) → cover-to-cover
> - You're deciding *why* something was built a certain way → §5
>
> **When to update it.** At the end of every module, before `git push`. The
> §11 change-log is the source of truth for "what happened when".
>
> ---
>
> **Sister docs (do not duplicate what's here).**
>
> | Doc | Purpose |
> |---|---|
> | [`INSTALL.md`](INSTALL.md) | The install-and-run guide: accounts, dev container, deploy, demo, teardown, and every problem hit in the real AWS run with its fix. Read this first if you're new. |
> | [`END-TO-END.md`](END-TO-END.md) | Architecture + flow diagrams |
> | [`../README.md`](../README.md) | Public-facing overview + doc map |
> | [`06-cost-tracker.md`](06-cost-tracker.md) | Free-tier cost log |
> | [`12-release-notes-v1.0.md`](12-release-notes-v1.0.md) | v1.0 release notes |
> | [`adr/`](adr/) | 4 Architecture Decision Records |
> | [`modules/*.md`](modules/) | Per-module delivery notes (Module 0's content is in INSTALL.md — no separate file) |
> | `docs-personal/` | Local-only study / interview / marketing notes (gitignored — not in the public repo) |
>
> **Currently completed:** Modules 0, 1, 2, 3, 3.1, 4, 4.1, 5.0, 6, 7.0, 8.0, 9.0, 10, 11, 12 — **project shipped as v1.0**,
> then deployed on real AWS, recorded and torn down on 23–25 Sep 2026
> (see §11 change-log for exact deliverables and dates).

<!-- toc -->
- [1. Mental model](#1-mental-model)
- [2. The Makefile — your one entry point](#2-the-makefile--your-one-entry-point)
- [3. Every script, explained](#3-every-script-explained)
- [4. Directory layout](#4-directory-layout)
- [5. Design decisions & why](#5-design-decisions--why)
- [6. Teardown strategy (very important — read this)](#6-teardown-strategy-very-important--read-this)
- [7. Secret handling](#7-secret-handling)
- [8. Environment variables](#8-environment-variables)
- [9. Idempotency contract](#9-idempotency-contract)
- [10. Troubleshooting](#10-troubleshooting)
- [11. Module change log](#11-module-change-log)
<!-- /toc -->

---

## 1. Mental model

There are **two layers** of AWS infrastructure with **very different
lifecycles**:

| Layer | What's in it | Cost | Lifecycle |
|---|---|---|---|
| **Permanent shared infra** | S3 tf-state bucket, DynamoDB tf-lock, SSM secrets, IAM `smartops-cli` user | < $0.05/mo | Created **once** (Module 0). Never destroyed until project retirement (`make nuke`). |
| **Workload infra** | 49 Terraform resources: VPC, EC2 (K3s nodes), EBS, Lambda, EventBridge, DynamoDB (incidents table), IAM roles, ECR repos | ~$0/day if within free tier | Created by `make tf-apply` at the start of a session (full order in [`INSTALL.md` §5](INSTALL.md#5-deploy-every-session)). **Destroyed nightly** by `make eod`. |

The **golden rule**: at the end of every session, run `make eod`. It's fast,
idempotent, and safe — it will not touch the permanent layer.

Only run `make nuke` when you are *permanently done* with the project (or you
want to reset from zero for testing).

---

## 2. The Makefile — your one entry point

```
make help          # show every target with a one-line description
```

You never need to remember which script goes where — `make` is the entry
point. Below is the full target catalog, grouped by intent.

### 2.1 Module 0 (local dev + shared infra) — one-time

| Command | Effect |
|---|---|
| `make setup` | Installs the toolchain in WSL Ubuntu (aws, terraform, kubectl, helm, k3sup, gh, poetry, jq, yq). Skips anything already installed. |
| `make bootstrap-backend` | Creates the S3 tf-state bucket and DynamoDB lock table (idempotent). Also writes `scripts/.backend-values` for Module 1 to consume. |
| `make put-secrets` | Reads `SLACK_WEBHOOK_URL` + `GROQ_API_KEY` from env vars and stores them in SSM as SecureString. Env-driven so nothing hits disk or shell history. |
| `make verify-secrets` | Shows SSM parameter metadata (names + timestamps only — never decrypts values). |
| `make init-repo` | Scans the tree for accidental secrets, then `git init` → commit → `gh repo create --public` → `git push`. |
| `make module-0` | Composite: runs `setup` + `bootstrap-backend`, then reminds you to run `put-secrets` manually with env vars, then `init-repo`. |

### 2.2 Daily lifecycle — every session

| Command | Effect |
|---|---|
| `make status` | **READ-ONLY**. One-glance summary: AWS identity, current-month cost, permanent-infra state, TF state count, K8s node count, count of billable resources. **Costs $0.01 per run** — the cost line calls the Cost Explorer API. |
| `make up` | Runs `tf-apply` → `kube-config` → `helm-install` → `verify`. On a fresh deploy it fails at `helm-install`, because Helm needs the SSM tunnel open and the images in ECR first; follow [`INSTALL.md` §5](INSTALL.md#5-deploy-every-session) instead. |
| `make eod` (alias `make down`) | **END-OF-DAY.** Uninstalls Helm releases → `terraform destroy` → deletes local kubeconfig → orphan check. Skips gracefully whatever doesn't exist yet. Asks you to type `YES` (`bash scripts/eod.sh --yes` skips the prompt). |
| `make verify` | Module-aware health check. Anything not deployed → SKIPPED. Anything deployed but unhealthy → FAILED. |
| `make check-orphans` | Fail if any billable AWS resource tagged `project=smartops-lite` still exists. Called automatically by `make eod`. |

### 2.3 Terraform (individual verbs)

| Command | Effect |
|---|---|
| `make tf-init` | `terraform init` in `infra/envs/dev` |
| `make tf-plan` | `terraform plan` |
| `make tf-apply` | `terraform apply -auto-approve` |
| `make tf-destroy` | `terraform destroy -auto-approve` (best-effort, skips if state doesn't exist) |

### 2.4 Kubernetes / Helm

| Command | Effect |
|---|---|
| `make kube-config` | Waits (up to 30 × 10 s) until SSM's `k3s_server_instance_id` matches the current server, fetches the kubeconfig from SSM, points it at `127.0.0.1:6443` (the SSM tunnel) and writes `~/.kube/config-smartops` |
| `make kube-api-tunnel` | Opens the SSM port-forward to the K3s API on `localhost:6443`. Runs in the foreground; keep its terminal open |
| `make helm-install` | `helm upgrade --install` for `ctrl` (namespace `smartops`) and `app` (namespace `demo`) (skips charts that don't exist yet) |
| `make helm-install-crashy` | Install only crashy-app; auto-injects `image.repository` from tf output |
| `make helm-install-controller` | Install only smartops-controller; auto-injects image + bus name from tf outputs |
| `make helm-uninstall` | Best-effort uninstall of both releases |
| `make deploy-crashy-app` | Alias for `helm-install-crashy` |

### 2.5 Image build / registry (Module 3+)

| Command | Effect |
|---|---|
| `make ecr-login` | `aws ecr get-login-password \| docker login` — needed once per shell |
| `make docker-build-crashy` | `docker build apps/crashy-app` → tags `:latest` and `:git-<sha>` |
| `make docker-push-crashy` | Depends on `ecr-login` + `docker-build-crashy`; tags then pushes both tags to ECR |
| `make docker-build-controller` | `docker build controller/` → tags `smartops-controller:latest` + `:git-<sha>` |
| `make docker-push-controller` | Depends on `ecr-login` + `docker-build-controller`; pushes both tags to ECR |

Override tag with `IMAGE_TAG=v1.2.3 make docker-push-crashy` (or `-controller`).

### 2.6 Module 5 — RCA pipeline (Lambda / DynamoDB / EventBridge rule)

| Command | Effect |
|---|---|
| `make logs-rca` | `aws logs tail /aws/lambda/smartops-lite-rca-generator --follow` — watch the Lambda live |
| `make invoke-rca-sample` | Publishes a synthetic `IncidentDetected` event to the bus (bypasses the controller — useful for smoke tests) |
| `make ddb-scan-incidents` | Table-scans `smartops-incidents` — prints `incidentId / reason / namespace / pod / ingestedAt / rcaStatus` |

The Lambda itself is deployed by `make tf-apply` (Terraform packages the zip, updates the function). No separate build target needed.

### 2.7 Module 7 — Remediator (Slack Ack button receiver)

| Command | Effect |
|---|---|
| `make put-signing-secret` | Reads `SLACK_SIGNING_SECRET` env var → SSM SecureString `/smartops/dev/slack_signing_secret`. Recommended pattern: `read -rs SLACK_SIGNING_SECRET; export SLACK_SIGNING_SECRET; make put-signing-secret`. |
| `make remediator-url` | Prints the public HTTPS URL of the remediator Lambda — paste into Slack app → Interactivity & Shortcuts → Request URL. |
| `make logs-remediator` | `aws logs tail /aws/lambda/smartops-lite-remediator --follow` — watch signature-verification + ack activity live. |
| `make ddb-scan-acked` | Table-scans `smartops-incidents` filtered on `rcaStatus=acknowledged` — prints `incidentId / reason / acknowledgedBy / acknowledgedAt`. |

The Lambda is deployed by `make tf-apply`. Setup flow: `make put-signing-secret` → `make tf-apply` → `make remediator-url` → paste into Slack.

### 2.8 Module 9 — MTTR Aggregator + Grafana observability

Scheduled Lambda (`rate(5 minutes)`) that scans `smartops-incidents`, computes up to 5 no-dimension SmartOps CloudWatch metrics (IncidentCount, AckedIncidentCount, AckRatePercent, LLMSuccessRatePercent, MTTRSecondsAvg), and an optional Grafana Cloud dashboard can read them via the CloudWatch data source. `MTTRSecondsAvg` is only published once an incident has been acknowledged, so the recorded run showed 4 metrics; Grafana wasn't set up in that run. Per-reason breakouts run as Logs Insights queries against the RCA Lambda log group (free within the 5 GB/mo ingest allowance). Full details in [`docs/modules/09-observability.md`](modules/09-observability.md).

| Command | Effect |
|---|---|
| `make invoke-mttr` | Fire the aggregator now with a synthetic Scheduled Event (`{"time": "<now>"}`) — useful to populate metrics without waiting 5 min. |
| `make logs-mttr-aggregator` | `aws logs tail /aws/lambda/smartops-lite-mttr-aggregator --follow` — watch scan → aggregate → publish live. |
| `make cloudwatch-metrics-mttr` | `aws cloudwatch list-metrics --namespace SmartOps` — confirm the series landed (4 until something is acknowledged). |
| `make grafana-dashboard-url` | Prints a pre-scoped Logs Insights URL used by the dashboard's breakout panels. |

Setup: `make tf-apply` (creates Lambda + schedule) → `make invoke-mttr` (populate) → import `dashboards/grafana/mttr-dashboard.json` in Grafana Cloud (see [`dashboards/grafana/README.md`](../dashboards/grafana/README.md)).

### 2.9 Verification & CI

| Command | Effect |
|---|---|
| `make lint` | Dispatch: ruff, mypy, hadolint, terraform fmt, tflint, yamllint, shellcheck (gracefully skips missing tools) |
| `make validate` | Static: `terraform validate` + `helm lint` (no AWS calls needed) |
| `make test` | `poetry run pytest` across every package with a `pyproject.toml` (auto-picks up `lambdas/rca-generator/`) |
| `make check` | Umbrella: `lint` + `validate` + `test` — this is what CI runs |

### 2.10 Chaos & demo (Module 10 — polished)

| Command | Effect |
|---|---|
| `make chaos-crash` | Hits `/crash` on one replica (via a Service port-forward) → `os._exit(1)` → the incident is reported as `Error`, exit code 1. Repeated crashes would end in `CrashLoopBackOff` |
| `make chaos-oom` | Hits `/oom` → allocate to 200Mi → OOMKilled (container limit is 128Mi) |
| `make chaos-error` | Hits `/500` → app-level HTTP error, pod stays healthy |
| `make chaos-slow` | Hits `/slow?ms=5000` → latency injection |
| `make chaos-info` | Prints each replica's pod / node / **actual zone** (joined against node's `topology.kubernetes.io/zone` label) |
| `make chaos-spread` | Asserts replicas span ≥ 2 distinct **zones** (not just nodes) — verifies Module 2's IMDS label + Module 3's hard anti-affinity are both working |
| `make pre-demo-check` | **Module 10** — one-shot read-only readiness check: toolchain + AWS identity + cluster reachability + deployment + SSM secrets + 4 TF outputs + SmartOps CW namespace populated. Exits 2 on warnings only (e.g. the optional signing secret), which `make` prints as `Error 2` |
| `make demo` | **Module 10** — ~90-second end-to-end demo (pre-flight → chaos → wait → DDB verify → force-invoke MTTR → CloudWatch listing → Grafana URL → cost). The cost step calls Cost Explorer ($0.01) only with `SHOW_COST=true` |
| `make demo-dry-run` | Rehearsal mode — banners fire in order but every AWS/cluster mutation is skipped |
| `make demo-reset` | `kubectl rollout restart` on crashy-app + wait for Ready — new pod names, so the next crash alerts again. Side effect: the replaced pods post 2 false `PodFailed` cards |

### 2.11 Cost

| Command | Effect |
|---|---|
| `make cost` | Current-month unblended spend, JSON. **Costs $0.01 per run** (Cost Explorer API) |
| `make cost-by-service` | Grouped by AWS service (only services > $0). **Costs $0.01 per run** |

The Billing console shows the same numbers for free.

### 2.12 Sanity

| Command | Effect |
|---|---|
| `make whoami` | AWS caller identity + region + kubectl context |

### 2.13 Local-only (kind) — no AWS

Local-only demo of Modules 1-3 (K3s + crashy-app + anti-affinity) on your
laptop using kind and a local Docker registry. Zero AWS cost. Coverage stops
at Module 3 — Modules 4-7 (Lambda, EventBridge, Slack notifier, SSM) genuinely
need AWS APIs.

| Command | Effect |
|---|---|
| `make local-up` | Runs `scripts/local-up.sh` → local registry + 2-node kind cluster (zone-labelled) + `docker build/push` crashy-app + Helm install. ~3 min. |
| `make local-down` | Runs `scripts/local-down.sh` → helm uninstall + `kind delete cluster` + registry container removed. Idempotent. |
| `make local-status` | Read-only: registry state + kind cluster list + local node/pod status. |
| `make devcontainer-verify` | Re-runs `.devcontainer/postCreate.sh` to verify every CLI (aws, terraform, kubectl, helm, kind, docker, gh, python, poetry, jq, yq, make, git). |

### 2.14 Nuclear options

| Command | Effect |
|---|---|
| `make nuke` | **PERMANENT.** Runs `eod`, then deletes the S3 tf-state bucket (all versions), DynamoDB lock table, all SSM secrets, IAM user `smartops-cli`, CloudWatch log groups, and local `.kube/config-smartops` + `scripts/.backend-values`. Requires typing `NUKE` to confirm. |

---

## 3. Every script, explained

Every script lives in `scripts/`. They're all idempotent (see §9) and take
their config from env vars (see §8), so calling them via `make ...` or
directly is equivalent.

### 3.1 `setup-wsl.sh` — install the WSL toolchain

**Purpose.** Bring a fresh Ubuntu-in-WSL to a fully working developer state.

**Runs when.** Once per new laptop, via `make setup`.

**Installs, in order.**
1. Base apt packages: `git curl unzip build-essential make python3 python3-venv python3-pip pipx jq wget gnupg ca-certificates`.
2. **aws-cli v2** — official installer from `awscli.amazonaws.com`. Skipped if `aws --version` already shows v2.
3. **tfenv** (clone to `~/.tfenv`) + Terraform 1.7.5 pinned via `tfenv install 1.7.5`.
4. **kubectl 1.29** — direct binary from `dl.k8s.io`.
5. **Helm 3** — official install script.
6. **k3sup** — installer runs in a `mktemp` dir so it never litters the cwd.
7. **gh** (GitHub CLI) — via apt with the official signed repo.
8. **poetry** — via `pipx install poetry`.
9. **yq** — pinned to v4.44.3.
10. **kind** — v0.23.0, for `make local-up`.
11. **AWS Session Manager plugin** — the official `.deb`; `make kube-api-tunnel` needs it.

**Reads env.** Nothing.

**Writes to disk.** Adds `export PATH="$HOME/.tfenv/bin:$PATH"` to `~/.bashrc` if missing. Everything else lands in `/usr/local/bin` or `~/.local/bin`.

**Exit codes.** 0 on success (including "already installed"). 1 on unexpected apt failure.

**Idempotent?** Yes — every step checks with `command -v` before installing.

### 3.2 `bootstrap-tf-backend.sh` — create S3 + DynamoDB backend

**Purpose.** Terraform needs a shared state store + lock table before you can run `terraform init` in `infra/envs/dev`. This creates them.

**Runs when.** Once per AWS account, via `make bootstrap-backend`.

**Creates.**
- **S3 bucket** `${PROJECT}-tf-state-${ACCOUNT_ID}` — versioned, AES256-encrypted, all-public-access-blocked, tagged.
- **DynamoDB table** `${PROJECT}-tf-lock` — PAY_PER_REQUEST, hash key `LockID` (S), tagged.

**Reads env.** `AWS_PROFILE` (default `smartops`), `AWS_REGION` (default `ap-south-1`), `PROJECT` (default `smartops-lite`).

**Writes to disk.** `scripts/.backend-values` (git-ignored, chmod 600). `make tf-init` sources it and passes the values to `terraform init` as `-backend-config` flags; nothing is copied into `backend.tf`.

**Exit codes.** 0 on success. 1 if `aws sts get-caller-identity` fails.

**Idempotent?** Yes — `head-bucket` + `describe-table` guards mean re-runs only re-apply versioning/encryption/tagging on the S3 bucket (which are themselves idempotent operations).

**Cost.** S3 + DynamoDB together < $0.02/month at project scale.

### 3.3 `put-secrets.sh` — store Slack + Groq secrets in SSM

**Purpose.** Get secrets *out* of `.env` files and *into* AWS SSM Parameter Store, where Lambdas + the controller can read them at runtime via IAM.

**Runs when.** Once per project (or when a secret rotates), via `make put-secrets`.

**Recommended invocation pattern (never puts secrets on disk):**
```bash
read -rs SLACK_WEBHOOK_URL   ; export SLACK_WEBHOOK_URL   # silent read
read -rs GROQ_API_KEY        ; export GROQ_API_KEY
make put-secrets
unset SLACK_WEBHOOK_URL GROQ_API_KEY
```

[`INSTALL.md` §4.2](INSTALL.md#42-store-the-slack-and-groq-secrets-in-ssm) has the paste-safe version used in the real run, which also strips invisible characters before storing.

**Reads env.** `SLACK_WEBHOOK_URL`, `GROQ_API_KEY`, `SLACK_SIGNING_SECRET` (optional), `AWS_PROFILE`, `AWS_REGION`, `PROJECT_ENV`.

**Writes to SSM.**
- `/smartops/${PROJECT_ENV}/slack_webhook` — SecureString
- `/smartops/${PROJECT_ENV}/groq_api_key` — SecureString

**Flags.** `--only-slack`, `--only-groq`, `--only-signing`, `--verify` (metadata only), `--help`.

**Idempotent?** Yes — but note the SSM quirk: `put-parameter --overwrite` cannot be combined with `--tags`. The script detects "already exists" and does `put-parameter --overwrite` (no tags) followed by a separate `add-tags-to-resource` call.

**Security.** No secret is ever passed as a command-line argument (which would show in `ps auxf`). No secret is ever written to disk. The script reads them from env only.

### 3.4 `init-repo.sh` — git init + gh repo create + push

**Purpose.** Turn the local scaffold into a public GitHub repo, but only after a secret-scan pass.

**Runs when.** Once, at the end of Module 0.

**What it does, in order.**
1. Checks that `git` and `gh` are installed and `gh` is authenticated.
2. **Secret scan.** Walks the working tree (not `git ls-files`, because on a fresh clone `git ls-files` returns nothing before `git init`). Scans every file except `.git/`, `.terraform/`, `node_modules/`, `.venv/`, `__pycache__/`, `dist/`, `build/`, and specific git-ignored secret files (`.backend-values`, `.env`, `*.tmp`). Six patterns: AWS key ID, AWS secret in ini, Groq `gsk_*`, Slack `xox*` tokens, Slack webhook URL, private keys.
3. `git init -b main` if `.git` doesn't exist.
4. `git add . && git commit` if working tree is dirty.
5. `gh repo create ${REPO_OWNER}/${REPO_NAME} --public` if not already on GitHub.
6. `git remote add origin git@github.com:...` if no origin.
7. `git push -u origin main`.

**Reads env.** `REPO_NAME` (default `smartops-lite`), `REPO_VIS` (default `public`), `REPO_OWNER` (defaults to your gh-authenticated login).

**Flags.** `--dry-run` (print intent, don't do it), `--help`.

**Idempotent?** Yes — every step guards against "already done" state.

### 3.5 `lint.sh` — polyglot linter dispatcher

**Purpose.** Run all appropriate linters. Skip missing tools gracefully.

**Runs.** `ruff`, `mypy`, `hadolint`, `terraform fmt -check`, `tflint`, `yamllint`, `shellcheck`.

**Exit codes.** 0 if nothing failed (including "no linters installed" or "no target directories yet"). Non-zero only on actual lint failures.

### 3.6 `validate.sh` — offline static validation

**Purpose.** Fast static checks that don't touch AWS or the cluster.

**Runs.** `terraform init -backend=false` + `terraform validate` in `infra/envs/dev` + `helm lint` (per chart under `helm/`).

**Exit codes.** 0 if nothing failed or nothing to check. 1 otherwise.

### 3.7 `test.sh` — pytest across packages

**Purpose.** Run `poetry run pytest` in every package that has a `pyproject.toml`.

**Exit codes.** 0 if all tests pass (including "no tests exist yet"). 1 on test failure.

### 3.8 `verify.sh` — module-aware smoke test

**Purpose.** Given whatever's currently deployed, verify it's healthy. Anything not yet built → SKIP (not fail).

**Checks, per module gate:**
- **Module 0:** aws sts, S3 tf-state bucket, DynamoDB tf-lock, SSM params.
- **Module 1+:** terraform state populated.
- **Module 2+:** k8s nodes Ready + span ≥ 2 AZs.
- **Module 3+:** `demo/smartops/observability` namespaces exist + `crashy-app` deployment Ready.
- **Module 4+:** EventBridge bus exists (`event_bus_name` from tf output) + `smartops-controller` deployment Ready + `/healthz` returns 200 in the pod.
- **Module 5+:** RCA Lambda `State=Active` + DDB incidents table `ACTIVE` + EventBridge rule attached to bus with target ARN + (informational) invocation count in the last hour.

**Flags.**
- `--with-slack` — additionally POST a test message to the Slack webhook. **Off by default** to avoid spamming `#smartops-alerts` on every run.
- `--module N` — only run checks for module ≤ N.

### 3.9 `check-orphans.sh` — the cost-safety enforcer

**Purpose.** Called at the end of `make eod`. Fails with a red ✘ if any billable AWS resource tagged `project=smartops-lite` still exists.

**Whitelist** (permanent shared infra, never orphans):
- S3 tf-state bucket (`smartops-lite-tf-state-*`)
- DynamoDB tf-lock table (`smartops-lite-tf-lock`)
- SSM params under `/smartops/*`
- IAM user `smartops-cli`

**Checks:** EC2 instances, EBS volumes, Elastic IPs, NAT gateways (should never exist), load balancers, EKS clusters (should never exist), RDS, ECR repos, DynamoDB workload tables, Lambda functions, custom EventBridge buses, SNS topics, CloudWatch log groups, VPCs, IAM roles.

**Exit codes.** 0 if clean. 1 if orphans found.

### 3.10 `eod.sh` — safe end-of-day teardown

**Purpose.** Destroy everything billable, keep the permanent infra.

**Steps.**
1. `helm uninstall` each release (best-effort per-namespace)
2. `terraform destroy -auto-approve` (only if `.terraform` exists)
3. Delete `~/.kube/config-smartops`
4. Run `check-orphans.sh`

**Flags.**
- `--yes` / `-y` — non-interactive (skip the "type YES" prompt)

**Idempotent?** Yes — every step guards for "not present" and skips.

### 3.11 `nuke.sh` — permanent retirement

**Purpose.** Delete EVERYTHING, including the permanent layer. Only use when done with the project forever, or when resetting from zero for testing.

**Steps.**
1. `eod.sh --yes` (destroys workload infra)
2. Empty and delete S3 tf-state bucket (all versions + delete markers)
3. Delete DynamoDB `smartops-lite-tf-lock`
4. Delete all SSM params under `/smartops/*`
5. Delete CloudWatch log groups `/aws/lambda/smartops*`
6. Delete IAM user `smartops-cli` (+ access keys + policies)
7. Remove local files: `~/.kube/config-smartops`, `scripts/.backend-values`, `infra/envs/dev/.terraform/`

**Requires** typing `NUKE` (uppercase) at the prompt.

### 3.12 `teardown.sh` — emergency nuclear (per-region)

**Purpose.** When `terraform destroy` gets stuck (rare — usually corrupted state or hand-edited resources). Force-terminates every EC2 + EBS tagged for the project, then re-runs `terraform destroy`, then `check-orphans.sh`.

**Not** the same as `nuke.sh`: this only handles EC2/EBS/TF, doesn't touch the permanent layer.

**Requires** typing `YES` at the prompt.

### 3.13 `status.sh` — one-glance dashboard

**Purpose.** Read-only. Show AWS identity, current-month spend, permanent-infra presence, workload-infra state, K8s cluster state, billable-resource counts.

**Never mutates**, but the spend line calls the Cost Explorer API, which costs **$0.01 per run**. On a strict $0 budget, use the Billing console instead.

### 3.14 `chaos.sh` — trigger a specific failure mode

**Purpose.** Called by `make chaos-crash`, `make chaos-oom`, etc. Opens a background `kubectl port-forward` to the crashy-app **Service** (so it needs no `kubectl exec` rights) and calls one endpoint on whichever replica answers.

**Types.** `crash` (`/crash`, exit 1) · `oom` (`/oom`, past the 128Mi limit) · `error` (`/500`) · `slow` (`/slow?ms=N`, default 5000) · `info` (pod / node / zone table) · `spread` (asserts ≥ 2 zones).

**Gotcha.** It hides `kubectl` errors, so `no crashy-app Service found` usually means the SSM tunnel is down, not that the app is missing.

### 3.15 `demo.sh` — the ~90-second scripted demo

**Purpose.** Reproducible walkthrough for a recording. Prints banners, triggers one crash, checks DynamoDB, force-invokes the MTTR aggregator and lists the CloudWatch metrics. Modes: default, `--dry-run`, `--reset`, `--skip-preflight`. The cost step is skipped unless `SHOW_COST=true` ($0.01 Cost Explorer call). Its banners say "CrashLoopBackOff" and mention Grafana; the real card shows `Error`, and Grafana is optional.

### 3.16 `local-up.sh` — spin up local kind cluster + crashy-app

**Purpose.** The "clone repo → one command → running app" path for reviewers who don't have (or don't want to burn) an AWS account. Zero cost, works offline.

**What it does (in order).**
1. Start a local Docker registry container (`kind-registry:5000`, host port 5001).
2. `kind create cluster --config .devcontainer/kind-config.yaml` — 2 nodes with `topology.kubernetes.io/zone` labels (`local-a`, `local-b`).
3. Attach the registry to kind's Docker network so containerd can pull from it via the registry mirror config.
4. Untaint the control-plane so both nodes are schedulable (only 2 nodes total).
5. Apply the `local-registry-hosting` ConfigMap (kind convention).
6. `docker build apps/crashy-app` + `docker push localhost:5001/smartops/crashy-app:local`.
7. `helm upgrade --install app helm/crashy-app` with `affinityMode=required`.
8. Wait for both pods Ready + print status.

**Devcontainer detection.** If `/.dockerenv` exists (i.e. running INSIDE a devcontainer), the script attaches its own container to the `kind` network and uses `kind get kubeconfig --internal` so kubectl works from inside.

**Idempotent.** Safe to re-run — every step checks existence first.

**Env vars.** `CLUSTER_NAME`, `REGISTRY_NAME`, `REGISTRY_PORT`, `NAMESPACE`, `RELEASE`, `IMAGE`, `IMAGE_TAG`, `KUBECONFIG_PATH`, `SKIP_BUILD`.

### 3.17 `local-down.sh` — tear down the local cluster

**Purpose.** Complement to `local-up.sh`. Uninstalls the Helm release → `kind delete cluster` → removes the registry container → deletes the local kubeconfig.

**Idempotent.** Safe on a machine that never ran `local-up.sh`.

**Env vars.** Same as `local-up.sh` + `KEEP_REGISTRY` (set to keep the registry running between cycles for faster restarts).

### 3.18 `pre-demo-check.sh` — one-shot readiness check before the Loom take

**Purpose.** Read-only guard-rail called by `make pre-demo-check`. Verifies everything the demo needs, so a bad take never comes from a missing prerequisite.

**Checks (in order).**
1. Toolchain — `kubectl`, `aws`, `jq` on `$PATH`.
2. AWS identity — `aws sts get-caller-identity` succeeds under `AWS_PROFILE=smartops`.
3. K8s cluster reachable — `kubectl cluster-info` responds.
4. `crashy-app` deployment ready (2/2), `smartops-controller` deployment ready (1/1).
5. SSM secrets present: `slack_webhook` and `groq_api_key` are required; a missing `slack_signing_secret` is only a warning.
6. 4 Terraform outputs present (bus name, incidents table, MTTR Lambda name, RCA Lambda name).
7. CloudWatch namespace `SmartOps` returns ≥1 metric (warning if not — run `make invoke-mttr` first).

**Exit codes.** `0` on all green, `1` on any red, `2` on warnings only (`make` prints that as `Error 2`). Prints a green ✔ per pass, a yellow ! per warning and a red ✘ per fail.

---

## 4. Directory layout

```
smartops-lite/
├── Makefile                    ← single entry point (see §2)
├── README.md                   ← public/recruiter-facing overview
├── .env.example                ← template for local env vars (git-tracked)
├── .env                        ← real values (git-IGNORED; never commit)
├── .gitignore
├── setup-windows.ps1           ← WSL bootstrap for Windows hosts (rarely used)
│
├── .devcontainer/              ← one-container-does-it-all dev environment
│   ├── Dockerfile              ← Ubuntu 24.04 + kind + yq + tfenv-pinned TF 1.7.5
│   ├── devcontainer.json       ← VS Code config + aws/kubectl/helm/gh/python features
│   ├── postCreate.sh           ← tool-version checks + welcome banner
│   ├── kind-config.yaml        ← 2-node local cluster (zones: local-a, local-b)
│   └── README.md               ← how to use the devcontainer
│
├── docs/                       ← public documentation (upload this)
│   │
│   │  ── canonical (current sources of truth) ──
│   ├── INSTALL.md              ← install-and-run guide: accounts → deploy → demo → teardown + troubleshooting
│   ├── END-TO-END.md           ← every architecture / flow / IAM / topology diagram (13 Mermaid)
│   ├── REFERENCE.md            ← this file — encyclopedia; §11 change-log = source of truth
│   ├── 06-cost-tracker.md      ← daily cost log
│   ├── 12-release-notes-v1.0.md ← ✅ Module 12 — v1.0 GitHub Release description
│   ├── modules/                ← 12 per-module deep-dive runbooks
│   ├── adr/                    ← 4 Architecture Decision Records
│   └── diagrams/               ← 11 standalone Mermaid sources (also inlined in END-TO-END.md)
│
├── docs-personal/              ← LOCAL ONLY (gitignored) — interview prep, curriculum, marketing, historical planning
│                                 see docs-personal/README.md
│
├── scripts/                    ← all bash automation (see §3)
│   ├── setup-wsl.sh
│   ├── bootstrap-tf-backend.sh
│   ├── put-secrets.sh
│   ├── init-repo.sh
│   ├── lint.sh
│   ├── validate.sh
│   ├── test.sh
│   ├── verify.sh
│   ├── check-orphans.sh
│   ├── eod.sh
│   ├── nuke.sh
│   ├── teardown.sh
│   ├── status.sh
│   ├── chaos.sh
│   ├── demo.sh
│   ├── pre-demo-check.sh       ← ✅ Module 10 — readiness gate before Loom take
│   ├── local-up.sh             ← kind cluster + registry + crashy-app (no AWS)
│   ├── local-down.sh           ← tear down the local kind cluster
│   └── .backend-values         ← auto-generated, git-IGNORED
│
├── infra/                      ← Terraform (Modules 1-9)
│   ├── modules/                ← 8 reusable modules (vpc, security-group, iam, k3s, ecr, eventbridge, dynamodb, lambda)
│   └── envs/dev/               ← the dev env root — where `terraform init` runs
│
├── apps/                       ← application code, one dir per microservice (Module 3+)
│   └── crashy-app/             ← FastAPI demo service (Module 3)
│
├── controller/                 ← ✅ Module 4 — Python K8s controller
│   ├── src/smartops_controller/  (config, detector, watcher, publisher, health, main)
│   ├── tests/                    (pure unit tests + moto-based publisher tests)
│   ├── Dockerfile
│   └── pyproject.toml
│
├── lambdas/                    ← Lambda functions (Modules 5, 7, 9)
│   ├── rca-generator/          ← ✅ Modules 5 + 6 — Groq RCA + Block Kit Slack
│   │   ├── src/rca_generator/  (config, schema, persistence, notifier, handler, rca_llm, slack_blocks)
│   │   ├── tests/              (7 files — all moto/urllib-mocked)
│   │   └── pyproject.toml
│   ├── remediator/             ← ✅ Module 7 — Slack Ack button receiver
│   │   ├── src/remediator/     (config, verify, persistence, slack, bus, handler)
│   │   ├── tests/              (conftest + 5 test files — all moto-mocked)
│   │   └── pyproject.toml
│   └── mttr-aggregator/        ← ✅ Module 9 — 5-min scan → 5 CloudWatch metrics
│       ├── src/mttr_aggregator/ (config, ddb_reader, aggregator, publisher, handler)
│       ├── tests/              (conftest + 4 test files)
│       └── pyproject.toml
│
├── helm/                       ← Helm charts
│   ├── crashy-app/             ← ✅ Module 3
│   └── smartops-controller/    ← ✅ Module 4
│
├── dashboards/                 ← ✅ Module 9
│   └── grafana/                (mttr-dashboard.json + import instructions)
│
├── .github/                    ← ✅ Module 8 — CI/CD
│   ├── workflows/
│   │   ├── ci.yml              ← lint + validate + test (3 parallel jobs)
│   │   └── security.yml        ← Trivy fs + Trivy config + Gitleaks
│   └── dependabot.yml          ← weekly bumps: GHA + Terraform + Docker + 5 × pip
│
├── .yamllint.yaml              ← ✅ Module 8 — yamllint config (skips Helm templates)
├── .hadolint.yaml              ← ✅ Module 8 — hadolint config (permissive on version pins)
└── .tflint.hcl                 ← ✅ Module 8 — tflint config (AWS ruleset, unused_declarations off)
```

**Convention.** Each module *adds* files but never touches files from previous
modules unless there's a design reason (which gets an ADR).

---

## 5. Design decisions & why

| Decision | Why | Alternative rejected |
|---|---|---|
| **K3s on EC2 t3.micro × 2, not EKS** | EKS control plane is $72/mo → violates free tier. | Kind/Minikube (single-node, no MTTR story). See `docs/adr/001-k3s-vs-eks.md`. |
| **Groq free tier as the only LLM** (model `qwen/qwen3.8-27b`, set by Terraform `llm_model`) | Free and fast, with an OpenAI-compatible API called through stdlib `urllib`, so there's no SDK in the Lambda zip. Fail-soft: if Groq fails, the incident still reaches DynamoDB and Slack with a placeholder RCA. | OpenAI (paid), Bedrock (not free tier). See `docs/adr/002-ai-backend-choice.md`. |
| **Terraform remote state (S3 + DDB)** | Multi-machine safe, versioned, encrypted. Nightly `terraform destroy` still works because state lives in the permanent bucket, not local disk. | Local state (`.tfstate` on laptop) — loses safety net. |
| **Two-tier infra (permanent vs. workload)** | You want to destroy compute nightly for cost, but not the state store (or you'd lose the memory of what to destroy). | Destroy everything nightly, re-bootstrap every morning — slow. |
| **SSM Parameter Store, not Secrets Manager** | Parameter Store SecureString is free for the volumes we have; Secrets Manager charges $0.40/param/mo. | Env vars in .env — leaks to git. |
| **Env-var-based secret input to `put-secrets.sh`** | Never lets secrets touch disk or command-line history. `read -rs` is silent. | `--slack-webhook-url=...` as a flag — appears in `ps auxf`. |
| **Makefile as the only entry point** | One file lists every operation; no shell history required. `make help` is self-documenting. | Standalone `smartops` CLI in Python — more code to maintain for zero benefit at this scale. |
| **Module-aware `verify.sh` and `eod.sh`** | You can run them at any point in the project's evolution and they degrade gracefully. | Hard-coded checks that only work at Module 11 — breaks on every intermediate day. |
| **`check-orphans.sh` whitelists permanent infra** | Without a whitelist, `make eod` would report false-positive orphans forever. | Delete permanent infra nightly → loses tf-state → catastrophic. |
| **Dev container for execution** (Docker Desktop on Windows in the recorded run) | Every CLI at a pinned version in one Linux image, so the same steps work on Windows, macOS and Linux. Native WSL / macOS / Linux still work ([`INSTALL.md` Appendix A](INSTALL.md#appendix-a-native-install-without-the-dev-container)). | Native Windows with Git Bash — the bash scripts and K3s tooling assume Linux. |

---

## 6. Teardown strategy (very important — read this)

You explicitly asked for this. Here's the full picture.

### 6.1 Three tiers of teardown

| Tier | Command | What it destroys | When to run |
|---|---|---|---|
| **T1 — session** | `make eod` (or its alias `make down`) | Helm releases, `terraform destroy` targets (EC2, EBS, VPC, Lambda, IAM roles, DDB workload table, EventBridge, SNS, ECR repos if in TF), local kubeconfig | **Every day** at the end of your work session |
| **T2 — nuclear (per session)** | `bash scripts/teardown.sh` | Force-terminates EC2 + EBS + retries `terraform destroy`, then orphan-checks | Only when `make eod` failed and you need to break glass |
| **T3 — retirement** | `make nuke` | Everything in T1+T2 **plus** S3 tf-state bucket (all versions), DDB tf-lock, SSM params, IAM `smartops-cli`, CloudWatch logs, local `.terraform/`, `.backend-values`, kubeconfig | Only when project is **permanently done** (or reset for testing) |

### 6.2 What stays alive after `make eod` (by design)

- **S3 tf-state bucket** (~ $0.01/mo)
- **DynamoDB `smartops-lite-tf-lock`** (~ $0/mo, on-demand billing)
- **SSM parameters** `/smartops/*` (free)
- **IAM user `smartops-cli`** (free)

Total permanent cost: **< $0.05/month**.

### 6.3 The safety net: `make check-orphans`

Runs automatically at the end of `make eod`. If it reports any orphans, the
exit code is non-zero and you'll see red ✘ marks. **Do not close your laptop
until it prints "No orphaned billable resources."**

Extend the script whenever we add a new resource type in a future module.

### 6.4 Cost circuit-breaker

No script creates a billing alarm. The recorded run relied on the AWS **Free
plan** (spend is drawn from credits, never charged to the card) plus an optional
**zero-spend budget** in AWS Budgets, set up by hand in
[`INSTALL.md` §1.1](INSTALL.md#11-aws-account-and-cli-user). If it ever emails
you, run `make eod` immediately. It's *belt-and-suspenders* on top of the
discipline above.

### 6.5 What happens if you forget

- Compute (EC2) is billed by the second — a forgotten cluster = ~$0.02/hour = $0.50/day. Not catastrophic but wasteful.
- **NAT gateway or Elastic IP** (unattached) would be $0.05–$0.30/hour. `check-orphans.sh` will scream about these — we never *plan* to create them, so it's a red flag if it does.
- The zero-spend budget (if you created it) emails you on the first cent.

---

## 7. Secret handling

### Never in git
- `.env` is in `.gitignore`.
- `scripts/.backend-values` (contains no true secrets, but treated as such) is in `.gitignore`.
- `scripts/init-repo.sh` scans the working tree with six regex patterns before every push.

### Never on command line
- `put-secrets.sh` reads env only. Callers use `read -rs` for silent input.

### Never in Terraform state
- The Slack webhook + Groq key are pulled from SSM at Lambda/controller runtime, not baked into the plan.

### Never in logs
- Every script that has a value in scope uses `>/dev/null` when calling AWS (so the response body — which for `ssm get-parameter --with-decryption` includes the value — never lands in stdout).
- `set -x` (bash trace) is never enabled by default.

### If a secret leaks
1. Rotate immediately at the source (Slack: recreate webhook; Groq: revoke and issue new key).
2. Re-run `make put-secrets` with the new value.
3. Restart Lambdas / controller to pick up the new value.

---

## 8. Environment variables

The full catalog. `.env.example` is the template; copy to `.env` (git-ignored) and fill in.

| Variable | Default | Used by | Notes |
|---|---|---|---|
| `AWS_PROFILE` | `smartops` | every script + Makefile | `aws configure --profile smartops` sets this up |
| `AWS_REGION` | `ap-south-1` | every script + Makefile | Mumbai — closest low-latency free-tier region for India |
| `PROJECT` | `smartops-lite` | Makefile + scripts | Prefix for bucket/table/IAM names |
| `PROJECT_ENV` | `dev` | Makefile + scripts | Prefix for SSM params (`/smartops/${PROJECT_ENV}/...`) |
| `SLACK_WEBHOOK_URL` | — (required) | `put-secrets.sh` | Only exists ephemerally in your shell; goes into SSM |
| `GROQ_API_KEY` | — (required) | `put-secrets.sh` | Same |
| `REPO_NAME` | `smartops-lite` | `init-repo.sh` | GitHub repo name |
| `REPO_VIS` | `public` | `init-repo.sh` | `public` or `private` |
| `REPO_OWNER` | (whoami on gh) | `init-repo.sh` | Override if you want to push to an org |
| `KUBECONFIG` | `~/.kube/config-smartops` | `verify.sh`, `chaos.sh`, `demo.sh`, `eod.sh` | Isolated from your other clusters |

---

## 9. Idempotency contract

Every script in `scripts/` MUST be safely re-runnable. That means:
- **Detect-before-create.** `head-bucket`, `describe-table`, `get-parameter`, `command -v` guards.
- **Best-effort teardown.** `helm uninstall`, `rm -f`, `iam delete-*` all `|| true` when appropriate.
- **No state files with side effects.** The only auto-generated file is `scripts/.backend-values`, which is git-ignored and safe to regenerate.

If you find a script that isn't idempotent, **that's a bug** — file it against
this file's "Module change log" (§11) and fix it.

---

## 10. Troubleshooting

This table covers script-level issues. Everything hit during the real AWS run
(Docker, AWS CLI, Terraform, the SSM tunnel, images, Slack, Groq, teardown) and
the bugs fixed along the way are in
[`INSTALL.md` §10](INSTALL.md#10-troubleshooting).

| Symptom | Likely cause | Fix |
|---|---|---|
| `aws sts get-caller-identity` fails | Wrong profile or expired keys | `aws configure --profile smartops` |
| `terraform init` says "backend not initialized" | Ran before `make bootstrap-backend` | `make bootstrap-backend` first |
| `put-secrets.sh` prints "Empty value for X — skipping" | Env var not exported | `export SLACK_WEBHOOK_URL=...` in the same shell |
| `make eod` says "cluster not reachable" | Kubeconfig deleted or cluster already down | Fine — that just means there's nothing to uninstall |
| `check-orphans.sh` reports EBS volumes | Instance terminated but EBS root volume set to "delete on terminate = false" in TF | Fix the TF (root_block_device { delete_on_termination = true }) |
| `nuke.sh` fails on S3 with "BucketNotEmpty" | Version cleanup missed something | Re-run `bash scripts/nuke.sh`; second pass gets stragglers |
| `init-repo.sh` says "gh not authenticated" | First time using gh | `gh auth login` (browser flow) |
| `terraform destroy` hangs on VPC | ENIs left behind by Lambda | Wait 5 min, re-run; or `bash scripts/teardown.sh` |
| `verify.sh` says "all N nodes in same AZ" but they're in different AZs | K3s not started with `--node-label topology.kubernetes.io/zone=...` | Fixed in audit 2.1 — re-apply Terraform to pick up the new cloud-init template. `terraform apply -replace=module.k3s_server.aws_instance.this` |
| `make helm-install` fails with "chart not found" | Running before Module 3 has landed | Fixed in audit 2.1 — target now prints "skip: helm/xxx" and continues. Update to latest Makefile. |

---

## 11. Module change log

Append one row here at the end of every module. Keep it terse.

| Date | Module | Files added | Files changed | Notable |
|---|---|---|---|---|
| 2026-08-04 | 0 — Local setup + AWS backend + repo bootstrap | `scripts/{bootstrap-tf-backend,put-secrets,init-repo,lint,validate,test,eod,nuke,status}.sh`, `.env.example`, `docs/modules/00-local-setup.md`, `docs/REFERENCE.md` | `Makefile` (composite + safe targets), `scripts/{verify,check-orphans,teardown,setup-wsl}.sh`, `.gitignore` | Two-tier teardown model established (T1 `eod`, T2 `teardown`, T3 `nuke`); `make status` for read-only snapshot; audited every script for `AWS_PROFILE` propagation |
| 2026-08-04 | 1 — Terraform: VPC + single-node K3s | `infra/envs/dev/{versions,providers,backend,variables,main,outputs}.tf` + `terraform.tfvars.example`; `infra/modules/{vpc,security-group,iam,k3s}/*` (13 files); `docs/modules/01-terraform-infra.md` | `Makefile` (`tf-init` sources `.backend-values`) | Single-node K3s on t3.micro, Ubuntu 24.04. No open ports — access via SSM port-forward. Cloud-init self-uploads kubeconfig + agent join token to SSM. VPC has 2 public subnets (Module 2 will use AZ-b). |
| 2026-08-04 | 2 — Multi-node K3s (add agent in AZ-b) | `docs/modules/02-multi-node-cluster.md` | `infra/envs/dev/{variables,main,outputs}.tf`, `scripts/verify.sh` | Wiring-only — reuses the k3s module with `role="agent"`. Added `enable_agent` toggle (default true) + `expected_node_count` output. `verify.sh` now checks TF for expected count and asserts ≥2 distinct AZs when ≥2 nodes present. No changes to reusable modules — proves the Module 1 design was extensible. |
| 2026-08-04 | 2.1 — End-to-end audit + fixes | — | `infra/modules/k3s/{variables,main,cloud-init.yaml.tftpl}`, `infra/envs/dev/{main,outputs}.tf`, `Makefile` (helm-install guard), `PROJECT_CONTEXT.md` §13 | **Bugs fixed:** (1) K3s nodes now get `topology.kubernetes.io/zone` + `region` labels from IMDS — anti-affinity + `verify.sh` AZ-spread check now actually work. (2) `env` var is threaded through the k3s module; cloud-init writes to `/smartops/${env}/*` instead of hardcoded `/smartops/dev/*`. (3) `make helm-install` now skips missing chart directories with a "skip:" message instead of erroring — makes `make up` work at any module stage. (4) Cleaned up misleading `outputs.tf` header comment. |
| 2026-08-04 | 2.2 — Doc consolidation | `docs/INSTALL.md` (new — canonical install guide, cross-platform) | `README.md` (new doc map + fresh repo layout), `PROJECT_CONTEXT.md` §16 (updated related-docs list), `docs/REFERENCE.md` (added sister-docs header) | **Deleted:** `docs/04-setup-guide.md` and `docs/modules/00-local-setup.md` — both were ~80% duplicates. Consolidated into single `docs/INSTALL.md` with Windows/WSL + macOS + Linux install paths. Established one-doc-per-purpose policy: INSTALL (how), REFERENCE (what/why), 01–03 (design/planning archive), 05–07 (ops/cost/marketing), ADRs (decisions), modules/ (per-module deep-dives). |
| 2026-08-24 | 4 — smartops-controller + EventBridge | `controller/{pyproject.toml,Dockerfile,.dockerignore,README.md,src/smartops_controller/{__init__,__main__,config,detector,publisher,watcher,health,main}.py,tests/{__init__.py,test_detector.py,test_publisher.py}}` (13 files); `helm/smartops-controller/{Chart.yaml,values.yaml,.helmignore,templates/{_helpers.tpl,deployment.yaml,service.yaml,serviceaccount.yaml,rbac.yaml,NOTES.txt}}` (8 files); `infra/modules/eventbridge/{main,variables,outputs}.tf`; `docs/modules/04-controller.md` | `infra/envs/dev/{main,variables,outputs}.tf` (wire eventbridge module, add `smartops/controller` to ECR list, expose `event_bus_name`/`event_bus_arn`); `infra/modules/iam/{main,variables}.tf` (new `attach_controller_policy` toggle + `event_bus_arn` var — grants events:PutEvents on ONE bus ARN); `Makefile` (new: `docker-build-controller`, `docker-push-controller`, `helm-install-controller`; `helm-install` composite now calls the new target); `scripts/{local-up,local-down}.sh` (auto-deploy controller in `DRY_RUN=true` for local kind path); `scripts/verify.sh` (new Module 4 gate: bus + Deployment + /healthz) | **Path 1 chosen: node IAM with least-privilege inline policy** (events:PutEvents on ONE bus ARN only). IRSA on K3s explicitly rejected as ~3× the code + first-time debugging risk; upgrade path documented in `docs/modules/04-controller.md` — the controller code is credential-source-agnostic so we can swap in IRSA later without touching Python. Controller architecture: watcher (K8s stream) → pure detector (Incident dataclasses) → LRU dedup (namespace,pod,container,reason) → publisher (EventBridge or DryRun). Emits `Source=smartops.controller`, `DetailType=IncidentDetected` with a stable v1.0 schema. Reasons detected: CrashLoopBackOff, ImagePullBackOff, ErrImagePull, CreateContainerConfigError, RunContainerError, OOMKilled, phase=Failed. Local kind path auto-runs controller in `DRY_RUN=true` mode so reviewers see the pipeline end-to-end without AWS. |
| 2026-08-24 | 3.1 — Dev container + local kind path | `.devcontainer/{Dockerfile,devcontainer.json,postCreate.sh,kind-config.yaml,README.md}`, `scripts/local-{up,down}.sh` | `Makefile` (new §2.10 targets: `local-up`, `local-down`, `local-status`, `devcontainer-verify`), `docs/INSTALL.md` (new §2A dev-container path + new §3 local-vs-AWS chooser; section renumbered), `docs/REFERENCE.md` (this row, §2.10, §3.16-3.17, §4 dir layout), `scripts/demo.sh` (fix stale selectors found in audit) | **Approach C (hybrid).** LocalStack rejected — Community edition lacks SSM SecureString + Lambda-in-VPC + IRSA, would diverge from real AWS. Instead: (a) `.devcontainer/` ships every CLI (aws, terraform, kubectl, helm, kind, docker, gh, python, poetry, jq, yq) in a reproducible Ubuntu 24.04 image; (b) `make local-up` spins a 2-node kind cluster + local registry + crashy-app for Modules 1-3 demo without any AWS account (~3 min, $0). Modules 4-7 still real-AWS. Kind config has explicit `topology.kubernetes.io/zone` labels (`local-a`, `local-b`) so hard anti-affinity actually spreads locally. |
| 2026-08-04 | 3 — crashy-app + Helm chart + ECR | `apps/crashy-app/{pyproject.toml,src/crashy/*,tests/*,Dockerfile,.dockerignore,README.md}` (8 files); `infra/modules/ecr/{main,variables,outputs}.tf`; `helm/crashy-app/{Chart.yaml,values.yaml,.helmignore,templates/{_helpers.tpl,deployment.yaml,service.yaml,serviceaccount.yaml,NOTES.txt}}`; `docs/modules/03-crashy-app.md` | `infra/envs/dev/{main,variables,outputs}.tf` (wire ECR module + expose URL outputs); `infra/modules/iam/{main,variables}.tf` (new `attach_ecr_read_only` toggle → managed policy `AmazonEC2ContainerRegistryReadOnly`); `Makefile` (new targets: `ecr-login`, `docker-build-crashy`, `docker-push-crashy`, `helm-install-crashy`, `chaos-{crash,oom,error,slow,info,spread}`; removed placeholder `build:`); `scripts/chaos.sh` (rewritten to use `app.kubernetes.io/*` selectors + real `/crash`,`/oom`,`/500`,`/slow` endpoints via Service port-forward) | First real workload lands on the cluster. FastAPI service with 4 failure endpoints (`/crash`, `/oom`, `/500`, `/slow`) + downward-API pod/node/zone identity headers. Helm chart uses **hard** `podAntiAffinity` on `topology.kubernetes.io/zone` — finally exercises the Module 2.1 label fix. ECR is a reusable module (`repository_names = [...]`) so Module 4 just adds `smartops/controller` to the list. Node IAM gains ECR read-only only when the toggle is on (kept off in Modules 1-2 for a minimal role). |
| 2026-08-24 | 4.1 — Post-Module-4 audit + fixes | `.gitattributes` (force LF for `.sh/.py/.tf/.yaml/etc.`) | `scripts/setup-wsl.sh` (CRLF → LF: bash was refusing to parse it; fixed `§5.1`/`§5.2` stale doc refs → `§6.1`/`§6.2`); `docs/INSTALL.md` (11 sub-section numbers under §4/§6/§7 renumbered to match parent §; §1 heading shortened to match its TOC anchor) | End-to-end static audit uncovered: (1) `setup-wsl.sh` was CRLF-tainted — would fail with `syntax error near unexpected token $'{\r''` on any WSL/Linux user's first `make setup`; (2) 11 INSTALL.md `###` headings had stale numbering after §2.2's top-level renumber; (3) TOC anchor for §1 didn't resolve on GitHub because I extended the heading text without updating the TOC. All three are now fixed and a `.gitattributes` prevents future CRLF drift. No production code touched. |
| 2026-08-26 | 12 — Interview prep + project retro + v1.0 release notes (**project shipped**) | `docs/12-interview-prep.md` (6 sections × ~40 anticipated interview questions each with a **30-second answer** for the recruiter-screen version and a **3-minute answer** for the technical follow-up; sections: behavioral / architecture / component deep dives / ops-cost-security / "what would you do differently" / curveballs; plus quick-reference card of 10 questions with 5-word answers and a "what to bring to the interview" packing list); `docs/12-retro.md` (honest post-mortem in 8 sections: what worked / what didn't / what got cut and why / lessons per pillar × 8 pillars with "do" and "don't" lists / what I'd do differently on day 1 / would-keep-would-trim-would-add / 13-row metrics table / closing); `docs/12-release-notes-v1.0.md` (draft GitHub Release description: TL;DR / What's included per subsystem / Numbers table / 4 design decisions with ADR links / Deferred features with rationale / Upgrade path from portfolio demo to production candidate in 7 steps / Tagging checklist as bash commands / Acknowledgements); `docs/modules/12-interview-retro-release.md` (module runbook explaining why 3 artifacts not 1, why 30-s + 3-min interview answers, why "what didn't work" front-and-center in retro, why release notes are a draft not a live tag, why upgrade path is included) | `README.md` (status line bumped: "Modules 0-10 complete" → "**v1.0** · Modules 0-12 complete"; new hero-row line linking release notes + interview prep + retro; doc map gained 3 rows for the new files with the interview prep row bolded); `docs/REFERENCE.md` (this row + `Currently completed` bumped to include 12 + "project shipped as v1.0" annotation); `PROJECT_CONTEXT.md` (status line bumped to "Modules 0-12 complete", Module 12 added to Completed list, "Immediate next step" updated to name the 5 remaining out-of-repo actions: publish to GitHub / record Loom / create v1.0 tag / post release announcement / practice interview prep) | **Why Module 12 exists as a separate module.** Modules 0-11 shipped code + tests + docs per feature, but nothing pulls the whole thing into a portfolio narrative. The retro answers "what actually happened", the interview prep answers "can they defend the design under questioning", the release notes answer "is it done and what would you do to prod-harden this". Different audiences (recruiter 30-s skim / hiring engineer 5-min deep dive / technical interviewer 30-min screen / future me 6-month re-read) need different reading surfaces. **Design decisions.** (1) **Three artifacts not one** — different reading contexts (spoken vs analytical vs scroll-to-scan), different maintenance cadences (refresh per interview cycle / snapshot / republish per version). (2) **Interview prep has both 30-s AND 3-min answers** — memorize 30-s until reflex, keep 3-min as graceful expansion; recruiter follow-ups get a scripted continuation not improvised rambling under screen pressure. (3) **Retro's "what didn't work" gets top-level section 2** not buried at the end — honest retros are more valuable to future me than marketing retros, and the interviewer's "what didn't work?" follow-up now has a paper trail. (4) **Release notes as a draft file** not a live tag — repo isn't on GitHub yet, but shipping the narrative doesn't require the artifact; tagging is a 4-command bash checklist at the bottom of the file. (5) **Upgrade path section in release notes** — 7 concrete steps from portfolio demo to production candidate (K3s→EKS Auto Mode, node IAM→IRSA, Groq→Bedrock, DDB Scan→GSI Query, add DLQ on RCA Lambda, SLO/error-budget dashboards, chaos experiments harness); answers the interviewer's "what would you do to make this real?" before it's asked. **Content decisions worth calling out.** Interview prep §6 curveballs section is not optional — real interviewers ask "why NOT this managed tool" and "what's your biggest architectural risk" and I want prepared answers with references, not improvised ones; every question references specific files (`hmac.compare_digest` in `remediator/verify.py`, `_now_from_event` in `mttr-aggregator/handler.py`, etc.) so answers stay concrete. Retro §7 numbers table is portfolio ammunition: "155 tests" as a top-line row is more useful than the same number buried in prose. Retro §4 has 8 per-pillar do/don't lists (IaC / K8s / Serverless / Observability / Security / Docs / Testing / CI/CD) — more useful than pure prose because an interviewer can dive into just the pillar their team cares about. **What's still manual after M12** (documented in §5 of the runbook so it's not a surprise): (a) publish repo to GitHub — `make init-repo` from Module 0 handles it, (b) record the Loom — `docs/11-loom-script.md` has the take-checklist, (c) create the v1.0 tag — 4-command checklist in the release notes, (d) post the LinkedIn/X release announcement — template in `docs/07-marketing.md`, (e) first real interview — practice with `docs/12-interview-prep.md`. **None of these block the code.** **Cost delta: $0/mo** (docs only). **Project shipped.** |
| 2026-08-26 | 11 — README polish + architecture diagram (Mermaid) + Loom recording script | `docs/diagrams/architecture.mmd` (Mermaid source, colored, 8 class definitions, regenerate PNG via `npx @mermaid-js/mermaid-cli` or mermaid.live paste); `docs/11-loom-script.md` (word-for-word narration table 13 rows × ~90 s targeting a recruiter's 30-s attention window; take checklist with pre-record window setup; per-window cue sheet — terminal / Slack / Grafana / DDB console fallback; failure-mode recovery table covering Slack card missing / DDB empty / CW empty / Grafana flat / SSM tunnel closed; post-production checklist; dry-run backup story); `docs/modules/11-readme-loom.md` (runbook explaining what was wrong with the old README, what M11 ships, 4 design decisions worth calling out, verification, what's still manual — recording + PNG generation + thumbnail + repo URL) | `README.md` (full rewrite — 133 → 220+ lines, 7 → 13 sections in new order title→status→hero(Loom)→what-it-does→WHY(4 design decisions)→HOW(architecture)→quickstart→doc-map→repo-layout→cost→skills→license; **fixed 5 lies in the old README**: stale status "Modules 0-8.0 complete" → "0-10", ASCII diagram named `fluent-bit`+`prometheus+grafana` neither of which is in the code → real 7-step pipeline diagram with EventBridge/Lambdas/DDB/Groq/Slack/CloudWatch/Grafana Cloud, "make demo available after Module 10" caveat removed, skills list dropped `Fluent Bit` and added `HMAC`+`Grafana Cloud`+`Function URL`, repo tree gained 4 missing subtrees: `apps/crashy-app/`, `lambdas/mttr-aggregator/`, `dashboards/grafana/`, `docs/diagrams/`; **added recruiter-facing content**: "Tests: 155 passing" badge, 90-second Loom placeholder + 3-command demo, "🎯 Four design decisions worth calling out" section linking each to ADR/runbook — K3s-not-EKS/Groq-not-Bedrock/Node-IAM-not-IRSA/aggregator-Lambda-not-Prometheus, per-service free-tier headroom bullets); `docs/REFERENCE.md` (this row + `Currently completed` bumped to include 11) | **Design decisions.** (1) **ASCII in the README, Mermaid source in `docs/diagrams/`, PNG optional** — ASCII renders identically on GitHub/CLI/VS Code/IDE hover, text-searchable, diff-friendly one-line PRs; Mermaid `.mmd` provides colored regeneratable source for the LinkedIn-preview PNG (kept as a separate artifact so README parses even before the PNG exists); the `.mmd` explicitly points at itself as source of truth in a top-of-file comment. (2) **Word-for-word Loom script, not bullets to riff on** — recruiters watch the first 30 s and a script optimizes for information density (every row has a quantified claim: `155 tests`, `5 metric series`, `10-metric free-tier ceiling`, `~1s Groq latency`); prevents dead-air ad-libbing. (3) **Loom placeholder, not a hard-coded URL** — the Loom is a manual out-of-repo step; making the README parse before recording lets M11 code work ship without blocking; anyone rendering pre-recording sees a call-out linking to the script. (4) **4-design-decision block goes ABOVE architecture** — old README hit architecture first, buried "why" in ADRs; new order title→status→hero→what-it-does→WHY→HOW→quickstart pushes decision rationale above the fold where recruiter attention actually flows top-down; each bullet still links to its full ADR/runbook so depth is present but not required for the skim. (5) **Zero-cost polish** — this module ships only docs + Mermaid + one recording script. **What's still manual**: (a) actual Loom recording (script is done, hitting Record is out-of-repo); (b) `docs/img/architecture.png` (Mermaid source committed; PNG is one `npx` command run by whoever cares about LinkedIn preview); (c) `docs/img/loom-thumb.png` (extract from recording); (d) real GitHub repo URL substituted for `dhanym/smartops-lite` if fork name differs. None of these block the code or the "does it work" story. **Verification**: (a) README renders on GFM (no unclosed lists/orphan headings/table misalignment/unbalanced code fences), (b) every doc link resolves to an existing file, (c) skills list is truthful — every listed skill has a code or docs referent (`hmac.compare_digest` in `remediator/verify.py`, Grafana Cloud in `dashboards/grafana/README.md`, Function URL in `infra/envs/dev/main.tf`). **Cost delta: $0/mo.** |
| 2026-08-26 | 10 — Polished chaos runner + demo orchestration (feeds Module 11 Loom recording) | `scripts/pre-demo-check.sh`; `docs/modules/10-chaos-demo.md` | `scripts/chaos.sh` (**bug fix**: `info` was reading `ZONE:.spec.nodeSelector` which is empty `{}` — zone lives on the NODE's `topology.kubernetes.io/zone` label; fixed via pods→nodes join in awk; `spread` now counts distinct zones not just nodes so a mis-labelled 2-node cluster is flagged instead of silently green); `scripts/demo.sh` (full rewrite: pre-flight block verifying kubectl/aws/deployment/SSM secrets → baseline `chaos-spread` → single `chaos-crash` trigger → 10s pod-watch → Slack narration pause → `aws dynamodb scan` verifying the incident row → `aws lambda invoke` on the MTTR aggregator with synthetic `{"time":"<now>"}` payload to force-refresh CloudWatch without waiting for a schedule tick → `aws cloudwatch list-metrics --namespace SmartOps` proving the 5 metric series are live → Grafana dashboard call-out → `aws ce get-cost-and-usage` for the current-month total; three modes: default full run, `--dry-run` fires banners without cluster/AWS mutations for rehearsal, `--reset` does `kubectl rollout restart` + wait for Ready in ~30 s between takes; `--skip-preflight` for CI; env knobs `PAUSE_SHORT/MED/LONG` for pace tuning); `Makefile` §2.10 (new: `demo-dry-run`, `demo-reset`, `pre-demo-check`; existing `demo` retained; `.PHONY` list expanded); `docs/REFERENCE.md` §2.10 (rewrote table for new zone semantics + new demo targets) + §"Currently completed" bumped to include 10 + §11 (this row) | **Design decisions.** (1) Pre-flight is default-on with `--skip-preflight` as escape hatch — Loom takes cost real minutes to record and a failed take because the SSM tunnel was closed 30 s earlier is expensive; (2) `--dry-run` also skips the `sleep` calls (via `pause() { $DRY_RUN && return 0; ... }`) so rehearsal fires in a few seconds while still walking the narration in order; (3) `--reset` uses `kubectl rollout restart` (~15-30 s) not `helm upgrade` (rebuilds Service/SA — 60+ s) — cheaper between takes; (4) demo force-invokes the MTTR aggregator during the run so the Grafana screenshot at `[01:15]` is populated in the same recording (schedule is `rate(5 minutes)` — waiting for a real tick would blow the 90 s timing); (5) no Slack tail: any check would need a Slack API token + read scope + channel ID + rate limiting for zero visual benefit — the `[00:35]` banner narrates what Slack is showing and the operator visually confirms in the Slack window during recording; (6) `spread` distinguishes 3 failure modes (single node → warn, 2+ nodes/1 zone → warn "missing IMDS labels", 2+ zones → ✓) so anti-affinity regressions are caught early. **No new AWS resources**; **zero cost delta**. Pure scripting polish that raises the M11 recording ceiling from "reasonable" to "one command, repeatable, 90 seconds, ends on a green metrics screen". LF-normalized all three scripts + `bash -n` syntax verified in WSL. |
| 2026-08-26 | 9.0 — MTTR Aggregator + Grafana dashboard (+ free-tier hardening) | `lambdas/mttr-aggregator/{pyproject.toml,README.md,src/mttr_aggregator/{__init__,config,ddb_reader,aggregator,publisher,handler}.py,tests/{conftest,test_aggregator,test_ddb_reader,test_publisher,test_handler}.py}` (12 files, 32 tests); `dashboards/grafana/{mttr-dashboard.json,README.md}`; `docs/modules/09-observability.md` | `infra/envs/dev/main.tf` (new `module.lambda_mttr_aggregator` + `aws_cloudwatch_event_rule.mttr_schedule` + target + `aws_lambda_permission.eventbridge_invoke_mttr`; **also fixed pre-existing terraform validate bug**: `lambda_rca` + `lambda_remediator` had mixed `Resource` types (string vs list) in `additional_policy_statements` — normalized all callers to `list(string)`); `infra/envs/dev/variables.tf` (new: `mttr_metric_namespace`, `mttr_window_minutes`, `mttr_schedule_expression`, `mttr_lambda_timeout_seconds`; **default `root_volume_gb` 20 → 15** so 2-node cluster fits 30 GB EBS free-tier ceiling); `infra/envs/dev/outputs.tf` (new outputs: `mttr_aggregator_{lambda_name,lambda_arn,log_group}` + `mttr_metric_namespace` + `mttr_schedule_rule_name` + `rca_lambda_log_group_insights_url`); `infra/envs/dev/terraform.tfvars.example` (root_volume_gb example bumped to 15); `infra/modules/lambda/variables.tf` (`additional_policy_statements.Resource` type: `any` → `list(string)` — enables strict list unification); `Makefile` (new §2.8: `logs-mttr-aggregator`, `invoke-mttr`, `cloudwatch-metrics-mttr`, `grafana-dashboard-url`); `docs/REFERENCE.md` §2.8 (new) + §2.9-§2.14 (renumbered) + §11 (this row) | **Design: Option D — lightweight Lambda every 5 min, scans DDB, computes 5 headline metrics in Python, publishes to CloudWatch, Grafana Cloud reads via CloudWatch data source.** Options A (Prometheus/Grafana on K3s — tight RAM), B (Grafana Mimir — overkill), C (direct DDB queries — no DDB data source) rejected. **Free-tier compliance the hard constraint.** 5 no-dimension metric series (`IncidentCount`, `AckedIncidentCount`, `AckRatePercent`, `LLMSuccessRatePercent`, `MTTRSecondsAvg`) fits the 10-metric free-tier ceiling with 100 % headroom. Per-reason and per-source breakouts move to **CloudWatch Logs Insights** queries against the existing RCA Lambda log group — free within the 5 GB/mo ingest allowance. **MTTR row eligibility**: only rows with BOTH `ingestedAt` AND `acknowledgedAt` contribute; unacked rows counted in `IncidentCount` but excluded (would bias toward window boundary). **Fail-loud on DDB Scan, fail-soft on CloudWatch PutMetricData** — mirrors RCA Lambda's split. **Handler reads `event["time"]`** (EventBridge always sets it) not wall clock — deterministic aggregation windows + trivial testability with `{"time": "..."}` in synthetic events. Falls back to wall clock if missing/malformed. **IAM least-privilege**: `dynamodb:Scan` on ONE table ARN + `cloudwatch:PutMetricData` gated by `cloudwatch:namespace=SmartOps` condition (API doesn't accept metric-level ARNs). **Bugs fixed in-flight**: (1) `test_handler_respects_window_env` was drifting with real wall-clock time until handler read `event.time` (would have masked as flaky test in real EventBridge deploys where fixture times differ from schedule ticks); (2) pre-existing `terraform validate` error in `additional_policy_statements` — mixed string/list Resource types wouldn't unify — noticed during Module 9's validate pass, would have blocked any `terraform apply` (fix touches lambda_rca + lambda_remediator + new mttr callers + the module type spec). **Cost breakdown** (verified in `docs/modules/09-observability.md` §6): Lambda invocations 8,640/mo (of 1M free), Lambda compute ~332 GB-s (of 400k free), CloudWatch metrics 5 (of 10 free), CloudWatch Logs ~5 MB (of 5 GB free), DDB Scan ~1200 RCU/mo (on-demand free tier), EventBridge scheduled events 8,640/mo (well under $1/M). **Total Module 9 cost: $0/mo.** Also opportunistically shrunk K3s EBS 20 → 15 GB so 2-node cluster stops overshooting the 30 GB EBS free-tier ceiling (was ~$0.80/mo, now $0). **Grafana Cloud setup**: sign up free tier → add CloudWatch data source with a purpose-built IAM user (only `cloudwatch:*` + `logs:StartQuery`/`GetQueryResults`) → import `dashboards/grafana/mttr-dashboard.json` (8 data panels, 3 rows, 4 headline stats + 2 trend charts + top-reasons table + RCA-source pie). Verified via **155/155 tests passing across all 5 packages** (crashy-app 8, controller 17, rca-generator 60, remediator 38, mttr-aggregator 32) + `terraform validate` green + `terraform fmt -check` shows no new drift. |
| 2026-08-26 | 8.0-verify — Post-M8 executable verification (real pytest + 3 bug fixes) | — | `controller/src/smartops_controller/publisher.py` (wrap `put_events` in try/except → raise `PublishError` on `ClientError` — was letting raw boto3 exceptions escape when bus doesn't exist or IAM/network fails); `lambdas/rca-generator/tests/test_handler.py` (`_install_stubs` was doing `monkeypatch.setattr(rca_llm.urllib.request, "urlopen", ...)` AND `notifier.urllib.request` — but both reference the SAME `urllib.request` module, so the second setattr silently overrode the first → Groq responses were coming back empty and Slack requests were being captured into the wrong list; rewrote to a single URL-dispatched stub that inspects `req.full_url` for `groq.com` vs anything else. 4 tests fixed with this one change: `test_end_to_end_happy_path_with_llm`, `test_llm_failure_falls_back_to_placeholder`, `test_slack_blocks_disabled_uses_plaintext`, `test_slack_disabled_still_persists`; also applied same pattern to `test_llm_disabled_via_env_skips_groq` + `test_schema_error_raises_before_llm_or_ddb`); `lambdas/remediator/tests/test_verify.py::test_missing_timestamp_raises` (regex `match="timestamp"` case-sensitive-mismatched actual `"missing X-Slack-Request-Timestamp"` → changed to `match="Timestamp"`) | **How this happened.** Module 8.0 shipped with green STATIC audit but I never actually ran `pytest`. When we did a full executable verification (moto DDB+SSM+EventBridge + urllib stubs + HMAC round-trip + cross-package schema contract), 6 tests failed. Traced to 3 root causes: (1) real EventBridge behavior differs from what the controller test expected — moto raises `botocore.errorfactory.ResourceNotFoundException` for missing bus, so the raw boto3 exception was escaping — fixed by wrapping in `PublishError`; (2) shared-module-attribute monkeypatch anti-pattern in `test_handler.py` — 4 tests actually shared one stub silently; fixed with URL dispatch; (3) case-sensitive regex mismatch. **After fixes**: **123/123 tests pass across all 4 packages** (crashy-app 8, controller 17, rca-generator 60, remediator 38). Also confirmed via full verification pass: (a) cross-package Incident dataclass 14-field alignment ctrl↔rca, (b) 3-way source/detail-type literal alignment publisher↔schema↔TF rule, (c) TF-declared env vars all have Python readers via helper functions (`_required`/`_bool`/`_reasons`), (d) HMAC round-trip accepts valid + rejects tampered/stale/missing, (e) Block Kit payload is Slack-conformant JSON with ≤50 blocks, (f) every .py AST-parses + byte-compiles, (g) every .yaml/.json/.toml parses. **Fresh-clone-viability status upgraded from "static-only-verified" to "runs 100% clean under real pytest".** No product logic changed. |
| 2026-08-25 | 8.0 — CI/CD: GitHub Actions + Dependabot + status badges | `.github/workflows/{ci,security}.yml`, `.github/dependabot.yml`, `.yamllint.yaml`, `.hadolint.yaml`, `.tflint.hcl`, `docs/modules/08-cicd.md` | `apps/crashy-app/pyproject.toml`, `controller/pyproject.toml`, `lambdas/rca-generator/pyproject.toml`, `lambdas/remediator/pyproject.toml` (all four relaxed `mypy strict = true` → `ignore_missing_imports + check_untyped_defs` — `strict = true` doesn't pass first-run because boto3/kubernetes/moto ship no type stubs; individual funcs still get typed-body checks); `scripts/lint.sh` (yamllint now uses `.yamllint.yaml` if present — Helm `{{ .Values.x }}` isn't valid YAML, so we exclude `helm/*/templates/*`); `README.md` (6 status badges below title: CI + Security + Python 3.12 + Terraform 1.7.5 + MIT license + AWS free tier — plus completion line bumped to "Modules 0–8.0"); `docs/REFERENCE.md` §4 (dir tree — new `.github/` + `.yamllint.yaml`/`.hadolint.yaml`/`.tflint.hcl`) §11 (this row) | **Two workflows, both parallel-job, `permissions: contents: read` least-priv.** `ci.yml` = 3 parallel jobs (`lint`, `validate`, `test`) that each just call `make lint` / `make validate` / `make test` — same three gates a dev runs locally. Runtime ~3-4 min wall-clock. Tool binaries pinned via `env:` block (`PYTHON_VERSION=3.12`, `TERRAFORM_VERSION=1.7.5`, `HELM_VERSION=v3.14.0`, `POETRY_VERSION=1.8.3`) so a Terraform 1.8 breaking change doesn't silently break CI; Actions themselves stay on `@v4`/`@v5` majors (Dependabot bumps them). Poetry venv cached (`~/.cache/pypoetry/virtualenvs`). **Concurrency group** with `cancel-in-progress: true` — new push to same ref cancels in-flight CI, saves ~5 min per rushed-commit sequence. `security.yml` = 3 parallel jobs (`trivy-fs`, `trivy-config`, `gitleaks`), triggered on push/PR + **weekly Monday 04:00 UTC cron** so we catch fresh CVEs on unchanged deps. Trivy scans **filesystem + IaC config** (not built image — image scan needs OIDC/ECR which is deferred to 8.1); SARIF uploaded to Security tab; skip-dirs excludes `.venv/`/`.terraform/`/`node_modules/`. Gitleaks does **full-history scan** (`fetch-depth: 0`) — catches historical accidental commits. **Fail policy**: `ci.yml` jobs all hard-block PR merge; `security.yml → trivy-*` reports SARIF-only (unpatched CVEs shouldn't freeze merges); `security.yml → gitleaks` hard-blocks (any committed secret is P0). `dependabot.yml` — 4 pip + 1 terraform + 2 docker + 1 github-actions = 8 ecosystem entries; minor+patch bumps **grouped as one PR per package per week**, majors unbundled (breakage likely). Monday 06:00 UTC (one hour after Trivy scan). **Config files** — `.yamllint.yaml` ignores Helm templates + relaxes `line-length: 200` (workflow `run: |` blocks trip default 80); `.hadolint.yaml` accepts DL3008/DL3013 (apt/pip pins already handled via poetry.lock + Ubuntu image); `.tflint.hcl` enables AWS ruleset v0.32.0 + disables `terraform_unused_declarations` (reusable modules intentionally expose vars). **mypy relaxation defensible** — `strict = true` was aspirational; `ignore_missing_imports=true + check_untyped_defs=true` still catches real bugs in the function bodies we wrote, just doesn't require type stubs for third-party libs. **Module 8.1 explicitly deferred** — `release.yml` (Docker build + ECR push + `terraform apply`) requires new `infra/modules/github-oidc/` producing an IAM role for GitHub OIDC federation (`aws_iam_openid_connect_provider` + trust policy scoped to this repo). Deferred because OIDC bootstrap is a one-time account-level IAM change best done alongside a real GH repo. Cost: **$0/mo** (public repo → free unlimited Actions minutes; private → ~600 free-tier min/mo used out of 2,000). Runtime: CI ~3-4min, Security ~2-3min. Portfolio impact: **green badges = 5-second recruiter-scan validation "this code works"**. |
| 2026-08-25 | 7.0 — Remediator: Slack Ack button receiver | `lambdas/remediator/{pyproject.toml,README.md,src/remediator/{__init__,config,verify,persistence,slack,bus,handler}.py,tests/{__init__,conftest,test_verify,test_persistence,test_slack,test_bus,test_handler}.py}` (14 files); `docs/modules/07-remediator.md` | `infra/envs/dev/{main,variables,outputs}.tf` (new `module.lambda_remediator` + `aws_lambda_function_url.remediator` + new local `ssm_slack_signing_secret_path` + `ssm_remediator_secret_arns`; new vars `allowed_remediation_reasons`/`slack_replay_window_seconds`/`remediator_lambda_timeout_seconds`; new outputs `remediator_lambda_{name,arn,log_group,function_url}` + `ssm_slack_signing_secret_path`); `scripts/put-secrets.sh` (new `--only-signing` mode + `SLACK_SIGNING_SECRET` env var + third SSM param); `Makefile` §2.7 (new: `logs-remediator`, `remediator-url`, `put-signing-secret`, `ddb-scan-acked`); `docs/REFERENCE.md` §2.6→§2.7 (new)/§2.8-§2.13 (renumbered)/§4 (dir tree)/§11 (this row) | **Closes the human-in-the-loop.** Module 6's Slack card had an Ack button that carried the `incidentId`; Module 7.0 wires the receiver end. **Design choice: Lambda Function URL, not API Gateway** — one endpoint, free HTTPS, no extra resource. **Second design choice: separate Lambda, not extending rca-generator** — different trigger (HTTP vs EventBridge), different IAM, different lifecycle. Flow per invocation: decode Function URL event → Slack HMAC verify (constant-time compare + 5-min replay window; **fail = 401**) → URL-decode form body + JSON-parse `payload=` → conditional DDB `UpdateItem` (`rcaStatus: generated→acknowledged` + `acknowledgedBy`/`acknowledgedAt`; **double-click is a happy path** — reads prior actor, echoes to Slack) → if reason ∈ `ALLOWED_REMEDIATION_REASONS`: `PutEvents` a `RemediationRequested` event (source=`smartops.remediator`, DetailType=`RemediationRequested`, v1.0 schema) for future Module 7.1 executor to consume (**fail-soft** — bus failure never rolls back ack) → response body replaces original Slack message: strips `smartops_actions` block, appends `smartops_ack_footer` context with `<@user>` + timestamp. **IAM least-privilege** — `dynamodb:UpdateItem/GetItem` on ONE table ARN, `events:PutEvents` on ONE bus ARN, `ssm:GetParameter*` on ONE param ARN, `kms:Decrypt` gated by `kms:ViaService=ssm.<region>.amazonaws.com`. **Reuses `infra/modules/lambda/`** — proves the Module 5 reusability pattern. **Module 7.1 (kubectl patch executor) explicitly deferred** — 3 design options with cost/complexity trade-offs documented in the runbook (Lambda-in-VPC $7+/mo, controller-via-SQS $0 but more code, skip $0). 39 tests across verify/persistence/slack/bus/handler — all moto (DDB+SSM+EventBridge) + HMAC-shaped-headers hermetic. Cost delta over Module 6: **$0/mo** (Lambda + Function URL + DDB + EventBridge all free tier at demo scale). |
| 2026-08-25 | 6 — Groq LLM RCA + Block Kit Slack | `lambdas/rca-generator/src/rca_generator/{rca_llm,slack_blocks}.py`; `lambdas/rca-generator/tests/{test_rca_llm,test_slack_blocks}.py`; `docs/modules/06-groq-slack.md` | `lambdas/rca-generator/src/rca_generator/{config,persistence,notifier,handler}.py` (LLM env vars in Config, new `rcaSource`/`rca_text` args on persist, `send_payload(dict)` in notifier, LLM step + Block Kit dispatch in handler; backward-compat: default kwargs preserve Module 5.0 shape); `lambdas/rca-generator/tests/{conftest.py,test_handler.py,test_notifier.py,test_persistence.py}` (Groq/Slack stubs, Module 6 assertions); `infra/envs/dev/{main,variables}.tf` (new vars `llm_enabled`, `llm_model`, `llm_timeout_seconds`, `llm_max_tokens`, `slack_blocks_enabled`, `rca_lambda_timeout_seconds`; wired into Lambda env vars; Lambda timeout 30s → 60s) | **AI-native moment.** Groq call inserted between parse and persist — 2-sentence RCA (cause + next action) via stdlib `urllib` to `api.groq.com/openai/v1/chat/completions`, default model `llama-3.3-70b-versatile`. Fail-soft: on any HTTP/timeout/malformed response, `rcaText` falls back to a placeholder + `rcaSource="fallback"` and DDB/Slack still fire. Slack now sends **Block Kit** — severity color mapped from `reason` (red = crash, orange = OOM, yellow = image, grey = other), header + context row (container/restarts/node/zone/exit) + kubelet message section + RCA block + "Acknowledge" button (`action_id="smartops_acknowledge"` value=`incidentId` — Module 7 wires the receiver) + footer (incident id + schema + timestamp). Backward-compat via `SLACK_BLOCKS_ENABLED=false` → falls back to Module 5.0 plain-text format. **No new AWS services, no IAM changes** — Groq key was already loaded from SSM in 5.0's cold-start `Secrets.load()`. DDB row shape adds `rcaSource` (`"groq"`/`"fallback"`/`"none"`) — existing 5.0 rows still parse (attribute is just missing). Zero external Python dependencies added; Lambda zip still < 60 KB. 32 tests total (was 28; added 9 for `rca_llm` + 11 for `slack_blocks`, extended 4 existing files). Prompt is structured tabular (1-1 map to Incident schema) + label filter to top-2 useful labels — keeps token budget < 200 typical. Cost delta: **$0/mo** (Groq free tier, Lambda still comfortably in free tier at demo scale). |
| 2026-08-24 | 5 — RCA pipeline: rule + Lambda + DDB + Slack | `infra/modules/dynamodb/{main,variables,outputs}.tf`; `infra/modules/lambda/{main,variables,outputs,.gitignore}.tf`; `lambdas/rca-generator/{pyproject.toml,README.md,src/rca_generator/{__init__,config,schema,persistence,notifier,handler}.py,tests/{__init__,conftest,test_schema,test_persistence,test_notifier,test_handler}.py}` (13 files); `docs/modules/05-rca-lambda.md` | `infra/envs/dev/{main,variables,outputs}.tf` (wire dynamodb + lambda modules + EventBridge rule/target/permission; add `incidents_table_name` + `slack_notifications_enabled` vars; expose `incidents_table_*`/`rca_lambda_*`/`incident_rule_*` outputs); `Makefile` (new §2.6: `logs-rca`, `invoke-rca-sample`, `ddb-scan-incidents`); `scripts/verify.sh` (Module 5 gate rewritten: pulls actual names from TF outputs; checks Lambda `State=Active` + DDB `ACTIVE` + rule→target ARN wiring + last-hour invocation count via CloudWatch); `docs/REFERENCE.md` §2.6 (new)/§2.7-§2.12 (renumbered)/§3.8 (updated)/§4 (dir tree — new modules + rca-generator sub-tree) | **Scope: Module 5.0 = Lambda + DDB + basic Slack ping** (Fluent Bit → 5.1 later, Groq LLM → Module 6). Zero external Python dependencies — boto3 is Lambda-runtime-bundled, Slack uses stdlib `urllib.request`. Deployment zip < 50 KB, cold-start < 300 ms. Design highlights: (a) per-rule Lambda architecture rejected in favor of "shared router" to keep IAM tight and blast radius contained; (b) idempotent-by-`incidentId` DDB writes (unconditional PutItem — re-invocations safe); (c) fail-loud on schema errors (EventBridge retries) but fail-soft on Slack (never blocks DDB); (d) cold-start-only SSM secret fetch (single GetParameters call, both Slack + Groq keys in one shot, ready for Module 6); (e) IAM least-privilege — DDB on ONE table ARN, SSM on TWO specific parameter ARNs, KMS Decrypt gated by `kms:ViaService=ssm.<region>.amazonaws.com`; (f) DDB shape adds `ingestedAt`/`rcaText`/`rcaStatus` fields to the incoming controller schema — Module 6 flips `rcaStatus: pending → generated` without any DDB migration. New TF modules `dynamodb/` + `lambda/` are reusable — future modules add more Lambdas by instantiating one block. |
| 2026-09-23 → 25 | First real AWS run + recording | — | `infra/modules/lambda/main.tf`; `infra/modules/k3s/{main.tf,cloud-init.yaml.tftpl}`; `infra/envs/dev/{main,variables}.tf`; `Makefile` (`kube-config`); `apps/crashy-app/.dockerignore`; `helm/crashy-app/templates/deployment.yaml`; `scripts/demo.sh`; `.devcontainer/Dockerfile`; `scripts/setup-wsl.sh` | First deploy on a real account (AWS Free plan, `ap-south-1`): 49 Terraform resources, 2 K3s nodes in 2 AZs, `make chaos-crash` → Slack card with a Groq RCA, DynamoDB row, 4 SmartOps CloudWatch metrics. Recorded, then `make eod` reported no orphans. 15 bugs fixed on the way; the full list with causes is in `docs/INSTALL.md` §10.8. Default model changed to `qwen/qwen3.8-27b` after Groq retired Llama 3.3 70B. The Acknowledge button wasn't wired to Slack and Grafana wasn't set up in this run. `make test`: 159 tests pass (8 / 19 / 60 / 40 / 32). |
| 2026-10-20 | Doc consolidation for the public repo | — | `README.md` (single project overview); `docs/INSTALL.md` (single install-and-run guide, following the recorded run); `docs/REFERENCE.md`; `docs/END-TO-END.md`; `docs/diagrams/`; release notes; ADR-002; module docs; `scripts/{setup-wsl,bootstrap-tf-backend}.sh` (doc pointers and messages); `.devcontainer/postCreate.sh` (welcome banner text); `.devcontainer/Dockerfile` and `infra/modules/lambda/main.tf` (whitespace and comment formatting only); `.gitattributes`; `.gitignore` (now keeps `apps/crashy-app/poetry.lock`, like the other four lock files) | **Deleted** `docs/RUN-GUIDE.md` (merged into INSTALL). **Moved** `PROJECT_CONTEXT.md` out of the public repo (personal notes). All text files normalised to LF. Removed claims that didn't match the run: billing alarm, Llama model, `make up` as the deploy path, Grafana as part of the demo. Fixed a space after a `\` in `setup-wsl.sh` that broke the `kind` download (native-install path only; the recorded run used the dev container). Nothing else changes behaviour; the deployed system is untouched. |

