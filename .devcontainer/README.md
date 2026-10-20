# SmartOps-Lite — Dev Container

A one-container dev environment. Ships every CLI SmartOps-Lite needs (aws v2 + Session Manager plugin, terraform 1.7.5, kubectl 1.29, helm 3, kind, docker, gh, python 3.12, poetry, jq, yq, make, git). No WSL/Homebrew/apt gymnastics on the host — just Docker + a devcontainer client. This is the environment the recorded AWS run used; the full walkthrough is [`docs/INSTALL.md`](../docs/INSTALL.md).

## Quickstart

### Option 1 — VS Code (recommended)
1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) + [VS Code](https://code.visualstudio.com/) + the *Dev Containers* extension
2. `git clone https://github.com/DhanyaM2001/smartops-lite.git && cd smartops-lite` (use `git clone`, not a ZIP download, so line endings stay LF)
3. Open in VS Code
4. Command Palette → **Dev Containers: Reopen in Container**
5. First build: ~2 min. You land in a shell with every tool ready.

### Option 2 — CLI (no VS Code)
```bash
# Install the CLI once
npm install -g @devcontainers/cli

# From the repo root:
devcontainer up --workspace-folder .
devcontainer exec --workspace-folder . bash
```

## What's inside

| Tool | Version | Source |
|---|---|---|
| aws | v2 | devcontainer feature |
| session-manager-plugin | latest | Dockerfile (needed by `make kube-api-tunnel`) |
| terraform | 1.7.5 (pinned via tfenv) | Dockerfile |
| kubectl | 1.29 | devcontainer feature |
| helm | 3 latest | devcontainer feature |
| kind | 0.24 | Dockerfile |
| docker (CLI) | Uses HOST daemon (docker-outside-of-docker) | devcontainer feature |
| gh | latest | devcontainer feature |
| python | 3.12 | devcontainer feature |
| poetry, pipx | latest | devcontainer feature |
| yq | latest | Dockerfile |
| jq, make, git, curl, wget, unzip | latest | apt |

## The Docker-outside-of-Docker model

The `docker` CLI inside the devcontainer talks to your **host's Docker daemon** (via a mounted socket). This means:
- Containers you start inside the devcontainer show up on your host's `docker ps`
- The `kind` cluster `make local-up` creates is on the host — accessible from either the devcontainer or the host
- No nested Docker slowness

## Two paths after entering

**A. Local-only demo** (no AWS account needed) — `make local-up` spins a kind cluster + local registry + deploys crashy-app. Zero cost, works offline. On Docker Desktop for Windows this failed in testing: the kubelet won't start because the cgroup v2 `cpuset` controller isn't delegated. Even when it works, the controller runs in dry-run mode.

**B. Real AWS demo** (the tested path) — follow [`docs/INSTALL.md`](../docs/INSTALL.md) from §3: `aws configure --profile smartops`, `make bootstrap-backend`, `make put-secrets`, then the deploy steps in §5. Don't use `make module-0` (it re-runs host setup the container already has) or `make up` (not a one-shot on a fresh deploy).

The container sets `AWS_PROFILE=smartops`, `AWS_REGION=ap-south-1` and `KUBECONFIG=/home/vscode/.kube/config-smartops` for every terminal.

Both paths use the same devcontainer.

## Persistent AWS credentials (optional)

By default, your host's `~/.aws/credentials` is NOT mounted into the devcontainer — each time you rebuild the container, you `aws configure` again. If you want persistence, add this to your local `.devcontainer/devcontainer.json` (do not commit — it hardcodes your host home):

```jsonc
"mounts": [
  "source=${localEnv:HOME}/.aws,target=/home/vscode/.aws,type=bind,consistency=cached"
]
```

Trade-off: convenient, but if you accidentally commit that line to git it'll fail on other people's machines because their `~/.aws` layout differs.

## Rebuild / troubleshoot

- **Rebuild container:** Command Palette → *Dev Containers: Rebuild Container*
- **Reset everything:** delete the container from Docker Desktop → reopen VS Code → *Reopen in Container*
- **See postCreate output again:** `bash .devcontainer/postCreate.sh` in the terminal

## Ports auto-forwarded to host

| Port | Purpose |
|---|---|
| 18080 | `chaos.sh` port-forwards crashy-app here |
| 3000 | Grafana (Module 9) |
| 6443 | K3s / kind API server |
| 5001 | Local kind registry (used by `make local-up`) |
