# SmartOps-Lite — Install and Run Guide

This is the one guide you need to build SmartOps-Lite on your own AWS account, run the crash demo, and tear it all down again. It follows the exact steps of the recorded run on 25 Sep 2026, including every problem hit along the way and how it was fixed.

- **Tested path:** Windows 11, Docker Desktop (WSL 2 engine), VS Code dev container, AWS region `ap-south-1` (Mumbai). macOS and Linux work the same way inside the dev container; a native install without the container is in [Appendix A](#appendix-a-native-install-without-the-dev-container).
- **Time:** about 90 minutes the first time (mostly account sign-ups), then about 30 minutes per session.
- **Cost:** $0 billed. The run used the AWS Free plan; see [rule 3](#the-five-rules) for the only commands that cost money.

For what the project is and how it's designed, read the [README](../README.md). For what every script and `make` target does, see [REFERENCE.md](REFERENCE.md).

## Contents

- [0. Before you start](#0-before-you-start)
- [1. Create the accounts (once)](#1-create-the-accounts-once)
- [2. Get the code and open the dev container (once)](#2-get-the-code-and-open-the-dev-container-once)
- [3. Configure the AWS CLI (once per container)](#3-configure-the-aws-cli-once-per-container)
- [4. Bootstrap the state backend and secrets (once)](#4-bootstrap-the-state-backend-and-secrets-once)
- [5. Deploy (every session)](#5-deploy-every-session)
- [6. Run the demo](#6-run-the-demo)
- [7. Tear down (end of every session)](#7-tear-down-end-of-every-session)
- [8. Starting the next session](#8-starting-the-next-session)
- [9. Delete everything for good (`make nuke`)](#9-delete-everything-for-good-make-nuke)
- [10. Troubleshooting](#10-troubleshooting)
- [11. Command cheat sheet](#11-command-cheat-sheet)
- [Appendix A. Native install without the dev container](#appendix-a-native-install-without-the-dev-container)

---

## 0. Before you start

### What you need

| Item | Notes |
|---|---|
| A laptop with 8 GB+ RAM and ~15 GB free disk | Docker Desktop and the dev container image need the space |
| [Docker Desktop](https://www.docker.com/products/docker-desktop/) | On Windows, use the WSL 2 engine (the default) |
| [VS Code](https://code.visualstudio.com/) + the **Dev Containers** extension | Extension id `ms-vscode-remote.remote-containers` |
| [Git](https://git-scm.com/downloads) | To clone the repo (a ZIP download breaks the shell scripts; see [step 2](#2-get-the-code-and-open-the-dev-container-once)) |
| An AWS account | Created in [step 1.1](#11-aws-account-and-cli-user) |
| A Groq account | Free, no card. [Step 1.2](#12-groq-api-key) |
| A Slack workspace you own | Free. [Step 1.3](#13-slack-webhook) |

Every tool the project uses (AWS CLI v2, Terraform 1.7.5, kubectl, Helm, Docker CLI, Session Manager plugin, Python 3.12, Poetry, jq, yq, make) comes preinstalled in the dev container.

### The five rules

1. **Secrets never go in a file, a commit or a chat.** You paste them into a hidden prompt, the script stores them encrypted in AWS SSM Parameter Store, and you clear them from the shell.
2. **End every session with `make eod`.** It destroys everything that runs or bills, and keeps only the small permanent layer below.
3. **Don't call Cost Explorer.** Each Cost Explorer API request costs **$0.01**. That includes `make status`, `make cost`, `make cost-by-service`, any `aws ce …` command, and `make demo` with `SHOW_COST=true`. Check spend in the **Billing console** instead; viewing it is free.
4. **Run commands one line at a time, and type symbols by hand if a paste looks wrong.** In the real run, copy-paste silently changed `-` into an en dash and added invisible characters to an AWS key and a profile name. Every command in this guide is a single line for that reason.
5. **Run every `make` command from the repo root** (`/workspaces/smartops-lite` inside the container).

### What gets created, and when

| Layer | What | Created by | Deleted by |
|---|---|---|---|
| **Permanent** (≈ $0) | S3 bucket `smartops-lite-tf-state-<account-id>` (Terraform state), DynamoDB table `smartops-lite-tf-lock`, SSM SecureStrings `/smartops/dev/slack_webhook` and `/smartops/dev/groq_api_key`, IAM user `smartops-cli` | Steps 1 and 4, once | `make nuke` only |
| **Workload** | 49 Terraform resources: VPC, 2 × `t3.micro` K3s nodes, ECR, EventBridge bus and rules, DynamoDB `smartops-incidents`, 3 Lambdas, IAM roles, log groups | `make tf-apply`, each session | `make eod`, each session |

---

## 1. Create the accounts (once)

### 1.1 AWS account and CLI user

1. Sign up at [aws.amazon.com](https://aws.amazon.com/). New accounts choose a plan at sign-up. The recorded run used the **Free plan**, which runs on credits and never bills your card. A card is still needed for identity checks.
2. Signed in as the root user, turn on MFA: account menu → **Security credentials** → **Assign MFA device**.
3. Optional safety net: **Billing and Cost Management → Budgets → Create budget → Zero spend budget**, with your email.
4. Create the CLI user: **IAM → Users → Create user**, name `smartops-cli`, **Attach policies directly** → `AdministratorAccess` → **Create user**.
5. Create its key: open `smartops-cli` → **Security credentials** → **Create access key** → use case **Command Line Interface (CLI)** → confirm → **Create access key**.
6. Copy the **Access key ID** and **Secret access key** with the **Copy** buttons. The secret is shown only once. Don't hand-select the text or pass it through Notepad; that's how invisible characters got into the key in the real run.

> `AdministratorAccess` keeps a one-person demo account simple. Don't reuse this user anywhere else.

### 1.2 Groq API key

1. Sign in at [console.groq.com](https://console.groq.com/).
2. **API Keys → Create API Key**, name it `smartops-lite`, and copy the value. It starts with `gsk_`.

The RCA Lambda uses the model `qwen/qwen3.8-27b`. Groq retired the original model (Llama 3.3 70B) during the project; if it retires this one too, see [Groq returns 404](#106-the-pipeline-slack-groq-metrics).

### 1.3 Slack webhook

1. In a Slack workspace you own, create a channel `#smartops-alerts`.
2. Go to [api.slack.com/apps](https://api.slack.com/apps) → **Create New App** → **From scratch**. Name it `smartops-lite`, pick your workspace, and click **Create App**.
3. Under **Features → Incoming Webhooks**, switch **Activate Incoming Webhooks** on, click **Add New Webhook**, choose `#smartops-alerts`, and click **Allow**.
4. Copy the **Webhook URL**. It looks like `https://hooks.slack.com/services/T…/B…/…`.

You don't need Interactivity or the signing secret. The Slack "Acknowledge" button isn't connected in v1.0 (see the README's known limitations).

---

## 2. Get the code and open the dev container (once)

1. **Start Docker Desktop** and wait until it shows **Engine running**. Then check it in PowerShell:

   ```powershell
   docker version
   ```

   You need both a **Client** and a **Server** section. `The system cannot find the file specified` means the engine isn't running yet.

2. **Clone the repo with git.** Don't download a ZIP or copy the folder. The repo's `.gitattributes` keeps shell scripts in Linux line endings (LF); a ZIP or copy can turn them into Windows endings (CRLF), and bash then fails with `$'\r': command not found`.

   ```powershell
   git clone https://github.com/DhanyaM2001/smartops-lite.git
   ```

3. **Open it in the container.** In VS Code: **File → Open Folder** → `smartops-lite`, then `Ctrl+Shift+P` → **Dev Containers: Reopen in Container**. The first build takes a few minutes.

4. **Open a terminal.** The bottom-left corner shows `Dev Container: smartops-lite`. **Terminal → New Terminal** opens bash in `/workspaces/smartops-lite`.

5. **Check the tools:**

   ```bash
   make devcontainer-verify
   ```

   ```bash
   session-manager-plugin --version
   ```

   Every tool should show a green `✔`, and the plugin should print a version number. The plugin is what lets `kubectl` reach the cluster through an AWS SSM tunnel.

The container already sets `AWS_PROFILE=smartops`, `AWS_REGION=ap-south-1` and `KUBECONFIG=~/.kube/config-smartops`. Your AWS credentials live inside the container, so **rebuilding the container wipes them**; after a rebuild, repeat step 3.

---

## 3. Configure the AWS CLI (once per container)

1. Save the keys from step 1.1. Type the command by hand; a stray invisible character in `smartops` creates a profile that can't be found.

   ```bash
   aws configure --profile smartops
   ```

   Paste the access key ID and the secret, then enter `ap-south-1` for the region and `json` for the output format.

2. Turn off the AWS CLI pager. Without this, long outputs stop at `(END)` and the script waits for you to press `q`.

   ```bash
   aws configure set cli_pager "" --profile smartops
   ```

   ```bash
   echo 'export AWS_PAGER=""' >> ~/.bashrc && export AWS_PAGER=""
   ```

3. Check who you are:

   ```bash
   aws sts get-caller-identity
   ```

   The `Arn` must end in `:user/smartops-cli`. If you get `could not be found` or `SignatureDoesNotMatch`, see [10.2](#102-aws-cli).

---

## 4. Bootstrap the state backend and secrets (once)

In the dev container, **don't run `make setup` or `make module-0`**. They install a native WSL toolchain that the container already has. Run the two steps below directly.

### 4.1 Terraform state bucket and lock table

```bash
make bootstrap-backend
```

It creates the S3 bucket (versioned, encrypted, public access blocked) and the DynamoDB lock table, then writes their names to `scripts/.backend-values` (git-ignored). It ends with:

```text
✔ Terraform backend is ready.
✔ Wrote scripts/.backend-values (chmod 600, git-ignored)
```

`make tf-init` reads that file automatically, so there's nothing to copy into `backend.tf`. The script is safe to re-run.

### 4.2 Store the Slack and Groq secrets in SSM

Run each line on its own. Nothing appears while you paste a secret; that's expected. The `tr -cd '!-~'` part keeps only printable characters, which strips anything invisible that came along with the paste.

**Slack webhook:**

```bash
read -rsp "Paste Slack webhook URL, then Enter: " RAW; echo
```

```bash
export SLACK_WEBHOOK_URL=$(printf '%s' "$RAW" | tr -cd '!-~'); echo "len=${#SLACK_WEBHOOK_URL} starts=${SLACK_WEBHOOK_URL:0:34}"
```

You should see `starts=https://hooks.slack.com/services/`.

Optional: check the webhook works before storing it. It should print `ok`, and a message appears in `#smartops-alerts`.

```bash
curl -sS -X POST -H 'Content-type: application/json' --data '{"text":"smartops-lite webhook test"}' "$SLACK_WEBHOOK_URL"; echo
```

**Groq key:**

```bash
read -rsp "Paste Groq API key, then Enter: " RAW; echo
```

```bash
export GROQ_API_KEY=$(printf '%s' "$RAW" | tr -cd '!-~'); echo "len=${#GROQ_API_KEY} starts=${GROQ_API_KEY:0:4}"
```

You should see `starts=gsk_`.

**Store both, then clear them from the shell:**

```bash
make put-secrets
```

```bash
unset RAW SLACK_WEBHOOK_URL GROQ_API_KEY
```

`make put-secrets` prints `✔ Created /smartops/dev/slack_webhook` and `✔ Created /smartops/dev/groq_api_key`, plus a yellow `skip … slack_signing_secret` line. That third secret is only for the unconnected Acknowledge button, so the skip is expected.

To check what's stored at any time (values are never printed):

```bash
make verify-secrets
```

It lists two rows, `groq_api_key` and `slack_webhook`, both `SecureString`.

To replace one secret later, export just that variable the same way and run `bash scripts/put-secrets.sh --only-groq` or `bash scripts/put-secrets.sh --only-slack`.

### 4.3 Optional: run the offline checks

These need no AWS calls. Install each package's dev dependencies once, then run the tests and static checks:

```bash
for p in apps/crashy-app controller lambdas/rca-generator lambdas/remediator lambdas/mttr-aggregator; do (cd "$p" && poetry install --no-interaction --with dev --no-root); done
```

```bash
make test
```

```bash
make validate
```

`make test` runs pytest in each package and ends with `✔ test passed`. There are 159 tests in total: crashy-app 8, controller 19, rca-generator 60, remediator 40, mttr-aggregator 32. `make validate` runs `terraform validate` and `helm lint`.

---

## 5. Deploy (every session)

`make up` exists, but on a fresh deploy it can't work in one shot: Helm needs the SSM tunnel to be open and the images to be in ECR first. Follow these steps in order. Free-plan usage starts at step 5.3.

### 5.1 Initialise Terraform

```bash
make tf-init
```

It ends with `Terraform has been successfully initialized!`

### 5.2 Preview

```bash
make tf-plan
```

The last line should be:

```text
Plan: 49 to add, 0 to change, 0 to destroy.
```

Nothing is created yet. If the plan shows anything to change or destroy on a fresh session, stop and check that the previous `make eod` finished.

### 5.3 Create the infrastructure

```bash
make tf-apply
```

This **doesn't ask for confirmation**. It takes a few minutes and ends with:

```text
Apply complete! Resources: 49 added, 0 changed, 0 destroyed.
```

followed by the outputs. The two EC2 nodes now install K3s by themselves, which takes another 2–3 minutes.

Optional, while you wait: in the EC2 console, select `smartops-lite-k3s-server` → **Actions → Monitor and troubleshoot → Get system log**. Near the bottom you'll see `[bootstrap]` lines, and later `[mem]` memory reports every 15 minutes.

### 5.4 Fetch the kubeconfig

```bash
make kube-config
```

It may print a few `waiting for server i-… to finish bootstrapping (n/30)...` lines first; that's normal. It waits until the new server has published its kubeconfig, writes `~/.kube/config-smartops` pointed at `127.0.0.1:6443`, and prints `export KUBECONFIG=…`.

### 5.5 Open the tunnel (terminal 1)

The cluster's API port isn't open to the internet. `kubectl` reaches it only through an SSM port-forward:

```bash
make kube-api-tunnel
```

Wait for `Waiting for connections...` and **leave this terminal open** for the rest of the session. Use the **+** in the terminal panel to open terminal 2.

### 5.6 Check the nodes (terminal 2)

```bash
export KUBECONFIG=~/.kube/config-smartops
```

```bash
kubectl get nodes -L topology.kubernetes.io/zone
```

You should see two nodes, both `Ready`: the server (`ip-10-0-1-…`, role `control-plane`) in `ap-south-1a` and the agent (`ip-10-0-2-…`) in `ap-south-1b`. The K3s version is whatever K3s's stable channel offers on the day you deploy; the recorded run got `v1.36.4+k3s1`. If only one node shows, wait a minute and run it again.

### 5.7 Push the two images

`make eod` deletes the ECR repositories along with their images, so **push again every session**. Docker Desktop must be running, because the container uses the host's Docker.

```bash
make docker-push-controller
```

```bash
make docker-push-crashy
```

Each ends with two `digest: sha256:…` lines, one for `latest` and one for `git-<commit>`.

### 5.8 Install the apps

```bash
make helm-install
```

It installs the controller (release `ctrl`, namespace `smartops`) and the demo app (release `app`, namespace `demo`). Wait about 60 seconds for the images to download, then check:

```bash
kubectl get pods -A -o wide
```

You should see four pods, all `Running`:

- `kube-system`: `coredns-…` (the only system pod; the other K3s add-ons are switched off to save memory)
- `smartops`: `ctrl-smartops-controller-…`
- `demo`: two `app-crashy-app-…` pods, **one on each node**

```bash
helm list -A
```

It shows `app` in `demo` and `ctrl` in `smartops`, both `deployed`.

```bash
kubectl -n smartops logs -l app.kubernetes.io/instance=ctrl --tail=20
```

Look for `Found credentials from IAM Role: smartops-lite-node-role` and `loaded in-cluster kube config`. The controller gets its AWS access from the node's IAM role; there are no keys in the cluster.

### 5.9 Pre-flight check

```bash
make invoke-mttr
```

```bash
make pre-demo-check
```

The check should finish with `errors: 0` and `warnings: 1` (the optional Slack signing secret), then print `make: *** Error 2`. **That's expected:** the script uses exit code 2 to mean "warnings only". Running `make invoke-mttr` first stops it warning about empty CloudWatch metrics.

Optional: `make invoke-rca-sample` sends a fake incident (pod `smoke-test-pod`) straight to EventBridge. It tests Lambda, Groq, DynamoDB and Slack without the cluster, and adds one synthetic row to the incidents table.

---

## 6. Run the demo

### 6.1 Set up the screen

- **Terminal 1:** the tunnel from step 5.5.
- **Pane A:** `kubectl -n demo get pods -o wide -w`
- **Pane B:** `make logs-rca` (the RCA Lambda's logs), or `kubectl -n smartops logs -f -l app.kubernetes.io/instance=ctrl` (the controller's logs)
- **Pane C:** for the commands below.
- **Browser:** Slack open on `#smartops-alerts`.

In any new pane, run `export KUBECONFIG=~/.kube/config-smartops` first.

### 6.2 Show the zone spread

```bash
make chaos-spread
```

It should print `pods spread across 2 node(s) / 2 zone(s) — anti-affinity working`.

### 6.3 Crash a pod

```bash
make chaos-crash
```

What you'll see, within about 5 seconds:

- **Pane C:** `curl: (52) Empty reply from server`. Expected; the app kills itself mid-request.
- **Pane A:** one pod drops to `0/1` with RESTARTS `1`, then returns to `1/1`. Kubernetes restarted it.
- **Controller log:** a `published incident` line.
- **Lambda log:** `handler start`, `groq rca generated`, `persisted incident`, `slack notified`, `handler done`. In the recorded run the Lambda finished 3–4 seconds after the controller published.
- **Slack:** a card with the pod, node, zone, `Error`, exit code `1`, and Groq's two-sentence RCA.

**Why the card says `Error`, not `CrashLoopBackOff`:** `/crash` exits with code 1, and the detector reports that specific cause. `CrashLoopBackOff` is Kubernetes' waiting state between repeated crashes, which a single crash never reaches.

### 6.4 Show the evidence

Use the pod name with RESTARTS `1` from Pane A.

```bash
kubectl -n demo describe pod <pod-name>
```

The last state shows `Reason: Error`, `Exit Code: 1`, `Restart Count: 1`.

```bash
kubectl -n demo logs <pod-name> --previous
```

It shows `/crash invoked — exiting with code 1`.

```bash
make ddb-scan-incidents
```

There's a row for the pod with reason `Error` and status `generated`.

```bash
make invoke-mttr
```

```bash
make cloudwatch-metrics-mttr
```

The aggregator response shows `rowsScanned`, `metricsPublished` and `window_minutes: 60` (it counts the last 60 minutes). The metrics list shows `IncidentCount`, `AckedIncidentCount`, `AckRatePercent` and `LLMSuccessRatePercent`. `MTTRSecondsAvg` only appears after an incident is acknowledged, and the Slack Acknowledge button isn't connected in v1.0 (see the README's known limitations).

In the AWS console (viewing is free), the same story is in **DynamoDB → Tables → `smartops-incidents` → Explore table items**, **CloudWatch → Log groups → `/aws/lambda/smartops-lite-rca-generator`**, **CloudWatch → Metrics → `SmartOps`**, and **EventBridge → Event buses → `smartops-dev` → Rules → `smartops-lite-incident-detected` → Monitoring**.

### 6.5 Crash again

The controller reports each pod-and-reason pair **once**, with no expiry, so crashing the same pod again gives no new card. Crash the other pod by name instead:

```bash
kubectl -n demo get pods -o wide
```

Pick the pod with RESTARTS `0` and save its name:

```bash
POD=app-crashy-app-xxxxxxxxxx-xxxxx
```

```bash
kubectl -n demo port-forward pod/$POD 18080:8000 >/dev/null 2>&1 & sleep 2; curl -sS --max-time 3 http://127.0.0.1:18080/crash; kill $!
```

`Empty reply from server` is expected, and so is `kill: No such process`.

Once both pods have crashed, `make demo-reset` replaces them with new pods (new names, so new alerts). It also posts **two false `PodFailed` cards** for the old pods, a known limitation listed in the README.

### 6.6 Other options

- **Scripted demo:** `make demo-dry-run` is a rehearsal that changes nothing; `make demo` runs the full ~90-second version. Its banners say "CrashLoopBackOff" and mention Grafana, but the card shows `Error`, and Grafana wasn't set up in the recorded run. Its cost step is skipped unless `SHOW_COST=true`; leave that unset. The recording itself used the manual steps above.
- **Other failure modes:** `make chaos-oom` should produce an `OOMKilled` incident, but it wasn't exercised in the recorded run. `make chaos-error` (HTTP 500) and `make chaos-slow` (latency) only change the HTTP response; the pod doesn't fail, so there's no incident.
- **Self-healing:** `kubectl -n demo delete pod <pod-name>` shows Kubernetes creating a replacement in the same zone. A deliberate delete isn't a crash, so normally there's no card.

---

## 7. Tear down (end of every session)

Keep the tunnel open if you can; it lets `make eod` uninstall the Helm releases cleanly first. If the tunnel is closed, that step is skipped and Terraform removes everything anyway.

```bash
make eod
```

It shows a box listing what it will destroy and what it keeps, then asks `Proceed? [type YES to continue]:`. Type **`YES` in capitals**; anything else prints `aborted.` and changes nothing. Then it runs four steps:

1. Helm uninstall of `app` and `ctrl`.
2. `terraform destroy` of all 49 workload resources.
3. Deletes `~/.kube/config-smartops`.
4. Runs the orphan check, which must end with `No orphaned billable resources.`

The last line is `EOD complete — safe to close laptop.` The tunnel in terminal 1 exits with an error once the server is gone; that's expected.

**What stays:** the state bucket, the lock table, the IAM user, and the SSM parameters. Besides your two secrets, SSM keeps four values from the old server: `kubeconfig`, `k3s_join_token`, `k3s_server_url` and `k3s_server_instance_id`. That's by design. The next server overwrites them, and the instance-ID check stops anything from using the stale ones.

To double-check:

```bash
make check-orphans
```

```bash
terraform -chdir=infra/envs/dev state list
```

The second prints nothing when the state is empty. For spend, open **Billing and Cost Management** in the console (Free Tier and Bills pages); don't use `make cost`.

---

## 8. Starting the next session

1. Start Docker Desktop and reopen the folder in the container.
2. If the container was rebuilt, repeat [step 3](#3-configure-the-aws-cli-once-per-container). The backend and secrets from step 4 are still in AWS.
3. Run [step 5](#5-deploy-every-session) from the top. The image push in 5.7 is required every time, because `make eod` deleted the repositories.

---

## 9. Delete everything for good (`make nuke`)

When you're finished with the project:

```bash
make nuke
```

Type `NUKE` (capitals) to confirm. It runs `make eod`, then deletes the state bucket (every version), the lock table, all `/smartops/*` SSM parameters, the `/aws/lambda/smartops*` log groups, the IAM user `smartops-cli` with its keys, and the local kubeconfig and `scripts/.backend-values`. Because it deletes the CLI user it runs as, the AWS CLI stops working afterwards; that's expected.

Then delete the Slack app (api.slack.com/apps) and the Groq key by hand. `make nuke` wasn't run in the recorded run; that AWS account was closed when its Free plan period ended.

---

## 10. Troubleshooting

Every row below was hit in the real run unless it says otherwise.

### 10.1 Docker and the dev container

| Symptom | Cause | Fix |
|---|---|---|
| `docker version` says `The system cannot find the file specified` | Docker Desktop's engine isn't running | Start Docker Desktop and wait for **Engine running**. If it hangs on "starting", quit it, run `wsl --shutdown` in PowerShell, and start it again |
| `$'\r': command not found` or `syntax error near unexpected token $'{\r'` | Scripts have Windows line endings because the folder was downloaded or copied, not cloned | Clone with git. Quick fix inside the container: `find . -type f -name "*.sh" -print0 \| xargs -0 sed -i 's/\r$//'` |
| `session-manager-plugin: command not found` | An old container image from before the plugin was added | **Dev Containers: Rebuild Container**, or install it now: `curl -fsSL -o /tmp/smp.deb "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" && sudo dpkg -i /tmp/smp.deb && rm /tmp/smp.deb` |
| `make local-up` fails at the CNI step; the kind node's kubelet logs `missing controllers: cpuset` | Docker Desktop's VM doesn't pass the cgroup v2 `cpuset` controller into kind's node container | Not fixable from inside Docker Desktop. Use the AWS path, which is the real one. (Even when kind works, the controller runs in dry-run mode there.) |

### 10.2 AWS CLI

| Symptom | Cause | Fix |
|---|---|---|
| `The config profile (smartops) could not be found`, and `grep -E '^\[' ~/.aws/config ~/.aws/credentials` shows `[profile smartops ]` | An invisible character was pasted into the profile name | `sed -i -E 's/^\[profile smartops.*\]/[profile smartops]/' ~/.aws/config` and `sed -i -E 's/^\[smartops.*\]/[smartops]/' ~/.aws/credentials`, then `aws sts get-caller-identity` |
| `SignatureDoesNotMatch` | The key ID is right but the secret picked up a hidden character | Run `read -rsp "Paste your Secret Access Key, then press Enter: " SK; echo`, then `CLEAN=$(printf '%s' "$SK" \| tr -cd 'A-Za-z0-9+/'); echo "length=${#CLEAN} (must be 40)"; [ ${#CLEAN} -eq 40 ] && aws configure set aws_secret_access_key "$CLEAN" --profile smartops && aws sts get-caller-identity; unset SK CLEAN`. If the length isn't 40, create a new access key and use the **Copy** button |
| A command stops at `(END)` | The AWS CLI pager | Press `q`, then turn the pager off ([step 3.2](#3-configure-the-aws-cli-once-per-container)) |
| `Unable to locate credentials` after a container rebuild | `~/.aws` lives inside the container | Repeat [step 3](#3-configure-the-aws-cli-once-per-container) |
| `tail: cannot open '40'`, or a `-w` flag treated as a name | The paste turned `-` into an en dash (`–`) | Retype the dashes by hand |

### 10.3 Terraform

| Symptom | Cause | Fix |
|---|---|---|
| `scripts/.backend-values missing` | Step 4.1 wasn't run in this copy of the repo | `make bootstrap-backend` (safe to re-run; it finds the existing bucket and table) |
| `Error acquiring the state lock` | Another Terraform run holds the lock | Wait for it. If you're sure nothing else is running: `terraform -chdir=infra/envs/dev force-unlock <LOCK_ID>` |
| `no such file or directory` with `-chdir=infra/envs/dev` | The terminal isn't in the repo root | `cd /workspaces/smartops-lite` |
| Nothing changed after `make tf-plan` | `tf-plan` only previews | Run `make tf-apply` |

### 10.4 Reaching the cluster

| Symptom | Cause | Fix |
|---|---|---|
| `connection refused` or `Unable to connect to the server` for `127.0.0.1:6443` | The SSM tunnel closed. Session Manager drops idle sessions after about 20 minutes | Press `Ctrl+C` in terminal 1 and run `make kube-api-tunnel` again. Re-running it is always safe |
| `make chaos-…` says `no crashy-app Service found` | Usually the tunnel is down; the script hides `kubectl`'s own error | Check with `kubectl get nodes`, then fix the tunnel as above |
| `kubectl` tries `localhost:8080` | `KUBECONFIG` isn't set, or `make eod` deleted the file | `export KUBECONFIG=~/.kube/config-smartops`; after a teardown, redo step 5 |
| `make kube-config` keeps waiting, then says `never published its kubeconfig` | The server's boot script failed | Read its log. In the console: **EC2 → server → Actions → Monitor and troubleshoot → Get system log**. Or from the terminal: `aws ec2 get-console-output --instance-id "$(terraform -chdir=infra/envs/dev output -raw k3s_server_instance_id)" --latest --output text > tmp/server-console.log`, then `grep -E "\[bootstrap\]\|\[mem\]\|WARNING\|Killed process" tmp/server-console.log` |
| Only one node, or one `NotReady` | The agent is still joining | Wait a minute and check again |

### 10.5 Images and pods

| Symptom | Cause | Fix |
|---|---|---|
| Pods stuck in `ImagePullBackOff` | The images weren't pushed this session; `make eod` deletes the ECR repositories | Run step 5.7. Kubernetes retries the pull by itself; `kubectl -n demo delete pod <pod-name>` retries straight away |
| `docker push` / `docker build` can't connect to the Docker daemon | Docker Desktop isn't running on the host | Start it and run the push again |

### 10.6 The pipeline (Slack, Groq, metrics)

| Symptom | Cause | Fix |
|---|---|---|
| The card says **RCA (fallback)** and the row's status is `pending` | Groq didn't answer within 10 seconds (`groq call failed (soft) … The read operation timed out` in `make logs-rca`). It happened once in the run | Nothing to fix. The incident is still stored and posted; the next crash normally gets a Groq answer |
| Every card is fallback; the log shows `HTTP Error 404` | Groq retired the configured model | List the models your key can use: `GROQ_KEY=$(aws ssm get-parameter --name /smartops/dev/groq_api_key --with-decryption --query Parameter.Value --output text); curl -s https://api.groq.com/openai/v1/models -H "Authorization: Bearer $GROQ_KEY" \| jq -r '.data[].id' \| sort; unset GROQ_KEY`. Then put `llm_model = "<model-id>"` in `infra/envs/dev/terraform.tfvars` (git-ignored) and run `make tf-apply`; only the Lambda's settings change. Pick a model that finishes inside 200 tokens; the notes on `llm_model` in `infra/envs/dev/variables.tf` show which ones did |
| No card for a second crash of the same pod | Deduplication: one alert per pod and reason, no expiry | Crash the other pod ([6.5](#65-crash-again)), or `make demo-reset` |
| Two `PodFailed` cards right after `make demo-reset` | Kubernetes marks the deleted old pods `Failed`, and the detector doesn't check for deletion | Known limitation; ignore them |
| The card's text ends in `…` | Slack collapses long text | Click the card, or read the full RCA in DynamoDB |
| `make: *** Error 2` after `make pre-demo-check` | Exit code 2 means "warnings only" | Expected when the only warning is the Slack signing secret |
| No metrics in CloudWatch | The aggregator runs every 5 minutes and only counts the last 60 minutes | `make invoke-mttr` |

### 10.7 Teardown

| Symptom | Cause | Fix |
|---|---|---|
| `make eod` prints `aborted.` | You typed something other than `YES` | Run it again and type `YES` in capitals |
| `EOD finished but orphans found` | Something survived `terraform destroy` | Run `make eod` again. Last resort: `bash scripts/teardown.sh` force-destroys EC2 instances and EBS volumes tagged `project=smartops-lite` (type `YES`) |

### 10.8 Bugs found and fixed during the first AWS run

These are already fixed in this repo, so you shouldn't see them. They're listed so the history is complete, and so you know where to look if one comes back.

| What went wrong | Cause | Fix (file) |
|---|---|---|
| `terraform apply` failed: all three Lambda inline policies rejected as `MalformedPolicyDocument` | Optional fields such as `Condition` were rendered as `null` | Null fields are dropped before the policy is encoded (`infra/modules/lambda/main.tf`) |
| `make kube-config` printed success but wrote an empty kubeconfig | With `.ONESHELL`, a failure mid-`&&`-chain didn't stop the recipe | The recipe stops on errors, writes only on success, and points the file at `127.0.0.1` itself (`Makefile`) |
| The server never uploaded its kubeconfig (`ParameterNotFound`) | Ubuntu 24.04 has no `awscli` apt package; apt rejected the whole package list and the script died at `aws: command not found` | AWS CLI v2 is installed from Amazon's official zip (`infra/modules/k3s/cloud-init.yaml.tftpl`) |
| The agent couldn't join the server | The server published its public IP, but the security group only allows node-to-node traffic on private IPs | The server publishes its private IP (same file) |
| Pods couldn't pull from private ECR | K3s has no ECR credentials by default | The boot script installs `ecr-credential-provider` v1.29.0 before K3s starts; v1.30.0's download link returns 404 (same file) |
| Edits to the boot script never reached running nodes | cloud-init only runs on an instance's first boot | `user_data_replace_on_change = true` (`infra/modules/k3s/main.tf`) |
| A new agent joined a server that no longer existed | The old server's join token and URL were still in SSM | The server writes its instance ID to `k3s_server_instance_id` last; the agent and `make kube-config` wait for the ID they expect; the agent is replaced whenever the server is (k3s module, `infra/envs/dev/main.tf`, `Makefile`) |
| The "agent" was really a second standalone server, the server ran every default add-on, and zone labels were missing | In `VAR=… curl … \| sh -`, the settings went to `curl`, not to the installer | `curl … \| VAR=… sh -`, with `agent` stated explicitly and a check that `k3s-agent` is running (`cloud-init.yaml.tftpl`) |
| Nodes went offline in SSM after some hours; the console log showed repeated OOM kills | 1 GiB of RAM, no swap, unneeded services | K3s add-ons `traefik`, `servicelb`, `metrics-server` and `local-storage` disabled; `fwupd`, `ModemManager`, `udisks2`, `multipathd`, `apport`, `packagekit`, `unattended-upgrades` and the apt timers masked; 1 GiB swap file; a memory report to the console every 15 minutes (`cloud-init.yaml.tftpl`) |
| No way to open the tunnel | The Session Manager plugin wasn't in the toolchain | Added to `.devcontainer/Dockerfile` and `scripts/setup-wsl.sh` |
| Every RCA was fallback, with Groq `HTTP Error 404` | Groq retired `llama-3.3-70b-versatile` | Default `llm_model` is now `qwen/qwen3.8-27b`, chosen after testing the available models at the 200-token cap (`infra/envs/dev/variables.tf`) |
| The crashy-app image build failed on a missing `README.md` | `.dockerignore` excluded the README that `pyproject.toml` needs | Line removed (`apps/crashy-app/.dockerignore`) |
| `make demo-reset` ran the whole demo instead | The `RESET` flag variable was overwritten by a terminal colour code | Renamed to `RESET_MODE` (`scripts/demo.sh`) |
| A rollout restart of crashy-app hung forever | `maxSurge: 1` / `maxUnavailable: 0` with one-pod-per-zone anti-affinity and only two zones: the extra pod could never be scheduled | `maxUnavailable: 1`, `maxSurge: 0` (`helm/crashy-app/templates/deployment.yaml`) |
| `make demo` spent $0.01 per run | Its "cost so far" step called Cost Explorer | Opt-in with `SHOW_COST=true` (`scripts/demo.sh`) |
| The `kind` download in `scripts/setup-wsl.sh` would fail (found in the final doc review) | A space after a line-continuation `\` split the `curl` command | Trailing whitespace removed |

---

## 11. Command cheat sheet

| When | Commands |
|---|---|
| **Once** | Accounts (step 1) → clone and open the container (step 2) → `aws configure --profile smartops` → `make bootstrap-backend` → hidden prompts and `make put-secrets` → `unset …` |
| **Deploy** | `make tf-init` → `make tf-plan` → `make tf-apply` → `make kube-config` → terminal 1: `make kube-api-tunnel` → terminal 2: `export KUBECONFIG=~/.kube/config-smartops` → `make docker-push-controller` → `make docker-push-crashy` → `make helm-install` → `make invoke-mttr` → `make pre-demo-check` |
| **Demo** | `make chaos-spread` → `make chaos-crash` → `make logs-rca` → `make ddb-scan-incidents` → `make invoke-mttr` → `make cloudwatch-metrics-mttr` |
| **Look around** | `kubectl get pods -A -o wide` · `helm list -A` · `make chaos-info` · `make verify-secrets` · `make help` |
| **End of session** | `make eod` (type `YES`) → `make check-orphans` |
| **Retire** | `make nuke` (type `NUKE`) |
| **Never (cost $0.01 each)** | `make status` · `make cost` · `make cost-by-service` · `aws ce …` · `SHOW_COST=true make demo` |

---

## Appendix A. Native install without the dev container

The recorded run used only the dev container. These paths install the same tools on the host instead. They're kept for completeness but weren't exercised in that run. Afterwards, add `export AWS_PROFILE=smartops` and `export KUBECONFIG=~/.kube/config-smartops` to `~/.bashrc` (or `~/.zshrc`), because outside the container nothing sets them for you. Then continue from [step 3](#3-configure-the-aws-cli-once-per-container).

### Windows (WSL 2 + Ubuntu 24.04)

1. In PowerShell as Administrator: `wsl --install -d Ubuntu-24.04`, reboot, and create your Linux user.
2. Install Docker Desktop and enable your distro under **Settings → Resources → WSL Integration**. Check with `docker version` inside Ubuntu.
3. Clone the repo inside Ubuntu: `git clone https://github.com/DhanyaM2001/smartops-lite.git && cd smartops-lite`
4. Install the toolchain: `make setup`. It runs `scripts/setup-wsl.sh`, which installs AWS CLI v2, Terraform 1.7.5 (via tfenv), kubectl 1.29, Helm 3, k3sup, gh, Poetry, jq, yq, kind and the Session Manager plugin. It's idempotent and prints a version summary at the end.

### macOS

1. Install [Homebrew](https://brew.sh/) and Docker Desktop.
2. `brew install awscli tfenv kubectl helm gh poetry jq yq`, then `tfenv install 1.7.5 && tfenv use 1.7.5`.
3. Install the Session Manager plugin by following [AWS's guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
4. Clone the repo as above.

### Linux (Ubuntu)

Install Docker Engine (or Docker Desktop), then either run `make setup` (it targets Ubuntu) or install the tools by hand. Terraform must be 1.7.5, and the Session Manager plugin is required:

```bash
curl -fsSL -o /tmp/smp.deb "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" && sudo dpkg -i /tmp/smp.deb && rm /tmp/smp.deb
```

### Native-path issues

| Symptom | Fix |
|---|---|
| `docker: command not found` in WSL | Docker Desktop → **Settings → Resources → WSL Integration** → enable your distro → **Apply & Restart** |
| `permission denied` on `/var/run/docker.sock` | `sudo usermod -aG docker $USER`, then `wsl --shutdown` in PowerShell and reopen Ubuntu |
| `git clone` or `curl` fails with `server certificate verification failed` | Your network intercepts HTTPS (a TLS-inspecting proxy). Use a machine and network without one; don't import the proxy's certificates into this project |
