# syntax=docker/dockerfile:1.7
#
# SmartOps-Lite — Dev Container
#
# One image that ships with every CLI SmartOps-Lite needs. Anyone with Docker
# + VS Code (or the `devcontainer` CLI) clones the repo, "Reopen in Container",
# and gets a fully-loaded Ubuntu 24.04 shell in ~2 min. No WSL/Homebrew/apt
# gymnastics on the host.
#
# Layered strategy:
#   - Base image already ships git, curl, sudo, non-root `vscode` user
#   - Common tools (aws, kubectl, helm, gh, python) come from official
#     devcontainer FEATURES declared in devcontainer.json (they layer on top
#     of this Dockerfile automatically)
#   - This Dockerfile installs only the tools that don't have good features:
#     kind, yq, tfenv+Terraform 1.7.5 (features install latest; we pin)
#
# Image size target: < 1.2 GB
# ---------------------------------------------------------------------------

FROM mcr.microsoft.com/devcontainers/base:noble

ARG KIND_VERSION=v0.24.0
ARG TFENV_TF_VERSION=1.7.5

# System deps that features assume already exist
RUN apt-get update && apt-get install -y --no-install-recommends \
        make jq wget unzip build-essential ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/*

# kind — Kubernetes-in-Docker (used by `make local-up`)
RUN curl -fsSL -o /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64" \
    && install -m 0755 /tmp/kind /usr/local/bin/kind \
    && rm /tmp/kind

# yq — CLI YAML processor (no official devcontainer feature)
RUN curl -fsSL -o /usr/local/bin/yq \
        https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    && chmod +x /usr/local/bin/yq

# tfenv + a PINNED Terraform version — matches infra/envs/dev/versions.tf
# (Terraform is also available as a devcontainer feature, but it installs
#  "latest"; we want deterministic version pinning.)
RUN git clone --depth=1 https://github.com/tfutils/tfenv.git /opt/tfenv \
    && chown -R vscode:vscode /opt/tfenv \
    && ln -s /opt/tfenv/bin/tfenv /usr/local/bin/tfenv \
    && ln -s /opt/tfenv/bin/terraform /usr/local/bin/terraform

# Run tfenv install AS the vscode user so ~/.terraform-version lives in
# /home/vscode (not /root). Also pre-warms the plugin cache.
USER vscode
RUN tfenv install "${TFENV_TF_VERSION}" && tfenv use "${TFENV_TF_VERSION}"

# Poetry — installed via pipx in postCreate so it lands in /home/vscode/.local
# (which is on PATH once the shell starts).

# ---- AWS Session Manager plugin -----------------------------------------
# The K3s API has no public ingress; kubectl reaches it only through
# `aws ssm start-session` port-forwarding (make kube-api-tunnel), which
# requires this plugin.
USER root
RUN curl -fsSL -o /tmp/session-manager-plugin.deb \
        "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
    && dpkg -i /tmp/session-manager-plugin.deb \
    && rm /tmp/session-manager-plugin.deb

# ---- OCI labels ---------------------------------------------------------
LABEL org.opencontainers.image.title="smartops-lite-devcontainer" \
      org.opencontainers.image.description="Reproducible dev environment for the SmartOps-Lite project" \
      org.opencontainers.image.source="https://github.com/dhanym/smartops-lite"
USER vscode
