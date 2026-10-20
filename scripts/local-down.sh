#!/usr/bin/env bash
# scripts/local-down.sh — tear down the local kind cluster + registry.
#
# Complements scripts/local-up.sh. Idempotent — safe on a machine that
# never ran local-up in the first place.
#
# What it does:
#   1. helm uninstall the crashy-app release (if present)
#   2. kind delete cluster (if present)
#   3. Stop + remove the local registry container (if present)
#   4. Delete the local kubeconfig file
#
# Env vars:
#   CLUSTER_NAME       (default: smartops-local)
#   REGISTRY_NAME      (default: kind-registry)
#   NAMESPACE          (default: demo)
#   RELEASE            (default: app)
#   KUBECONFIG_PATH    (default: $HOME/.kube/config-smartops-local)
#   KEEP_REGISTRY      (default: unset — set any value to keep the registry
#                       container between local-up cycles for faster restarts)

set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-smartops-local}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
NAMESPACE="${NAMESPACE:-demo}"
RELEASE="${RELEASE:-app}"
CTRL_NAMESPACE="${CTRL_NAMESPACE:-smartops}"
CTRL_RELEASE="${CTRL_RELEASE:-ctrl}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config-smartops-local}"

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "  ${GREEN}\xe2\x9c\x94${RESET} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }

# ---- 1. helm uninstall ---------------------------------------------------
if command -v helm >/dev/null && [ -f "$KUBECONFIG_PATH" ]; then
  say "uninstalling helm release '${RELEASE}' from ${NAMESPACE}"
  KUBECONFIG="${KUBECONFIG_PATH}" helm uninstall "${RELEASE}" -n "${NAMESPACE}" 2>/dev/null \
    && ok "release uninstalled" \
    || warn "no release '${RELEASE}' found in namespace '${NAMESPACE}' (already gone)"

  say "uninstalling controller release '${CTRL_RELEASE}' from ${CTRL_NAMESPACE}"
  KUBECONFIG="${KUBECONFIG_PATH}" helm uninstall "${CTRL_RELEASE}" -n "${CTRL_NAMESPACE}" 2>/dev/null \
    && ok "controller uninstalled" \
    || warn "no release '${CTRL_RELEASE}' found in namespace '${CTRL_NAMESPACE}' (already gone)"
else
  warn "helm or kubeconfig unavailable — skipping helm uninstall"
fi

# ---- 2. kind delete cluster ----------------------------------------------
if command -v kind >/dev/null; then
  say "deleting kind cluster '${CLUSTER_NAME}'"
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    kind delete cluster --name "${CLUSTER_NAME}"
    ok "cluster deleted"
  else
    ok "cluster '${CLUSTER_NAME}' not present"
  fi
else
  warn "kind CLI not found — skipping cluster delete"
fi

# ---- 3. Registry ---------------------------------------------------------
if [ -n "${KEEP_REGISTRY:-}" ]; then
  warn "KEEP_REGISTRY set — leaving '${REGISTRY_NAME}' running"
else
  say "stopping local registry '${REGISTRY_NAME}'"
  if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || echo false)" = "true" ]; then
    docker rm -f "${REGISTRY_NAME}" >/dev/null
    ok "registry removed"
  else
    ok "registry '${REGISTRY_NAME}' not present"
  fi
fi

# ---- 4. Kubeconfig -------------------------------------------------------
if [ -f "$KUBECONFIG_PATH" ]; then
  say "removing kubeconfig ${KUBECONFIG_PATH}"
  rm -f "$KUBECONFIG_PATH"
  ok "removed"
fi

echo ""
ok "local teardown complete — 0 containers, 0 clusters, \$0 cost."
