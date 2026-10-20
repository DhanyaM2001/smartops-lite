#!/usr/bin/env bash
# scripts/local-up.sh — spin up a local kind cluster + registry + crashy-app.
#
# This is the "clone repo → one command → running app" path. Zero AWS cost,
# works offline, uses your laptop's Docker.
#
# What it does:
#   1. Start a local Docker registry container (kind-registry:5000, host port 5001)
#   2. Create a 2-node kind cluster (control-plane in local-a + worker in local-b,
#      with matching topology.kubernetes.io/zone labels)
#   3. Wire the registry to kind's docker network so containerd can pull from it
#   4. Untaint the control-plane so crashy-app pods can schedule on both nodes
#   5. Build crashy-app image + push to the local registry
#   6. helm install crashy-app pointing at localhost:5001/smartops/crashy-app
#   7. Wait for both pods Ready
#   8. Print next-step commands
#
# Env vars:
#   CLUSTER_NAME       (default: smartops-local)
#   REGISTRY_NAME      (default: kind-registry)
#   REGISTRY_PORT      (default: 5001)
#   NAMESPACE          (default: demo)
#   RELEASE            (default: app)
#   IMAGE              (default: localhost:${REGISTRY_PORT}/smartops/crashy-app)
#   IMAGE_TAG          (default: local)
#   KUBECONFIG_PATH    (default: $HOME/.kube/config-smartops-local)
#   SKIP_BUILD         (default: unset — set to any value to skip docker build)
#
# Idempotent: safe to re-run.
# Detects when it's running INSIDE a devcontainer and attaches to kind's
# docker network + writes an internal kubeconfig so kubectl works from there.

set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-smartops-local}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
NAMESPACE="${NAMESPACE:-demo}"
RELEASE="${RELEASE:-app}"
IMAGE="${IMAGE:-localhost:${REGISTRY_PORT}/smartops/crashy-app}"
IMAGE_TAG="${IMAGE_TAG:-local}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config-smartops-local}"
KIND_CONFIG="${KIND_CONFIG:-.devcontainer/kind-config.yaml}"

# Module 4: controller image (DRY_RUN=true mode by default for local demo).
CTRL_IMAGE="${CTRL_IMAGE:-localhost:${REGISTRY_PORT}/smartops/controller}"
CTRL_IMAGE_TAG="${CTRL_IMAGE_TAG:-local}"
CTRL_NAMESPACE="${CTRL_NAMESPACE:-smartops}"
CTRL_RELEASE="${CTRL_RELEASE:-ctrl}"
SKIP_CONTROLLER="${SKIP_CONTROLLER:-}"

# ---- helpers -------------------------------------------------------------
CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "  ${GREEN}\xe2\x9c\x94${RESET} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
die()  { printf "  ${RED}\xe2\x9c\x98${RESET} %s\n" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH"; }

# ---- 0. Sanity ----------------------------------------------------------
say "checking prerequisites"
need docker
need kind
need kubectl
need helm

if ! docker info >/dev/null 2>&1; then
  die "docker daemon is unreachable — is Docker Desktop / dockerd running?"
fi
ok "docker daemon reachable"

if [ ! -f "$KIND_CONFIG" ]; then
  die "kind config not found at $KIND_CONFIG"
fi
ok "kind config: $KIND_CONFIG"

INSIDE_CONTAINER=0
[ -f /.dockerenv ] && INSIDE_CONTAINER=1
if [ "$INSIDE_CONTAINER" -eq 1 ]; then
  warn "running INSIDE a container (devcontainer detected) — will use internal kubeconfig"
fi

# ---- 1. Local registry --------------------------------------------------
say "ensuring local registry '${REGISTRY_NAME}' on host port ${REGISTRY_PORT}"
if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || echo false)" != "true" ]; then
  docker run -d --restart=always \
    -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --network bridge \
    --name "${REGISTRY_NAME}" \
    registry:2 >/dev/null
  ok "started ${REGISTRY_NAME}"
else
  ok "${REGISTRY_NAME} already running"
fi

# ---- 2. kind cluster ----------------------------------------------------
say "ensuring kind cluster '${CLUSTER_NAME}'"
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  ok "cluster '${CLUSTER_NAME}' already exists"
else
  kind create cluster --name "${CLUSTER_NAME}" --config "${KIND_CONFIG}" --wait 90s \
    || die "kind create cluster failed"
  ok "cluster '${CLUSTER_NAME}' created"
fi

# ---- 3. Attach registry to kind's docker network ------------------------
say "connecting registry to kind network"
if ! docker network inspect kind >/dev/null 2>&1; then
  die "kind's docker network doesn't exist — cluster creation failed silently?"
fi
if docker network inspect kind -f '{{range .Containers}}{{.Name}} {{end}}' | grep -qw "${REGISTRY_NAME}"; then
  ok "already connected"
else
  docker network connect kind "${REGISTRY_NAME}"
  ok "connected ${REGISTRY_NAME} to network 'kind'"
fi

# ---- 4. Kubeconfig ------------------------------------------------------
say "writing kubeconfig to ${KUBECONFIG_PATH}"
mkdir -p "$(dirname "${KUBECONFIG_PATH}")"
if [ "$INSIDE_CONTAINER" -eq 1 ]; then
  # From inside a container, 127.0.0.1 doesn't reach the host — use kind's
  # internal DNS + attach ourselves to kind's docker network.
  docker network connect kind "$(hostname)" 2>/dev/null || true
  kind get kubeconfig --name "${CLUSTER_NAME}" --internal > "${KUBECONFIG_PATH}"
else
  kind get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG_PATH}"
fi
chmod 600 "${KUBECONFIG_PATH}"
ok "kubeconfig written"

export KUBECONFIG="${KUBECONFIG_PATH}"

# ---- 5. Untaint control-plane so pods can schedule on both nodes -------
say "untainting control-plane (2-node cluster needs both nodes schedulable)"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
ok "control-plane taint removed (if present)"

# ---- 6. Document the registry via ConfigMap (kind convention) ----------
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
ok "local-registry ConfigMap applied"

# ---- 7. Build + push crashy-app ----------------------------------------
if [ -n "${SKIP_BUILD:-}" ]; then
  warn "SKIP_BUILD set — skipping docker build/push (using whatever's already in the registry)"
else
  say "building crashy-app image → ${IMAGE}:${IMAGE_TAG}"
  docker build -q -t "${IMAGE}:${IMAGE_TAG}" apps/crashy-app >/dev/null \
    || die "docker build failed"
  ok "built ${IMAGE}:${IMAGE_TAG}"

  say "pushing to local registry"
  docker push -q "${IMAGE}:${IMAGE_TAG}" >/dev/null \
    || die "docker push failed — is the registry reachable at localhost:${REGISTRY_PORT}?"
  ok "pushed ${IMAGE}:${IMAGE_TAG}"
fi

# ---- 8. Helm install (crashy-app) --------------------------------------
say "helm upgrade --install ${RELEASE} helm/crashy-app -n ${NAMESPACE}"
helm upgrade --install "${RELEASE}" helm/crashy-app \
  --namespace "${NAMESPACE}" --create-namespace \
  --set image.repository="${IMAGE}" \
  --set image.tag="${IMAGE_TAG}" \
  --set image.pullPolicy=Always \
  --set affinityMode=required \
  --wait --timeout 90s \
  || die "helm install failed — inspect: kubectl -n ${NAMESPACE} describe pods -l app.kubernetes.io/instance=${RELEASE}"
ok "helm release '${RELEASE}' ready"

# ---- 8b. Controller (Module 4) — DRY_RUN mode locally ------------------
if [ -n "${SKIP_CONTROLLER}" ]; then
  warn "SKIP_CONTROLLER set — skipping smartops-controller"
elif [ ! -d controller ] || [ ! -d helm/smartops-controller ]; then
  warn "controller/ or helm/smartops-controller/ not present — skipping (Module 4 not written yet?)"
else
  if [ -n "${SKIP_BUILD:-}" ]; then
    warn "SKIP_BUILD set — reusing existing controller image in registry"
  else
    say "building controller image → ${CTRL_IMAGE}:${CTRL_IMAGE_TAG}"
    docker build -q -t "${CTRL_IMAGE}:${CTRL_IMAGE_TAG}" controller >/dev/null \
      || die "controller docker build failed"
    ok "built ${CTRL_IMAGE}:${CTRL_IMAGE_TAG}"
    docker push -q "${CTRL_IMAGE}:${CTRL_IMAGE_TAG}" >/dev/null \
      || die "controller docker push failed"
    ok "pushed ${CTRL_IMAGE}:${CTRL_IMAGE_TAG}"
  fi

  say "helm upgrade --install ${CTRL_RELEASE} helm/smartops-controller -n ${CTRL_NAMESPACE}  (DRY_RUN=true)"
  helm upgrade --install "${CTRL_RELEASE}" helm/smartops-controller \
    --namespace "${CTRL_NAMESPACE}" --create-namespace \
    --set image.repository="${CTRL_IMAGE}" \
    --set image.tag="${CTRL_IMAGE_TAG}" \
    --set image.pullPolicy=Always \
    --set env.DRY_RUN=true \
    --set env.EVENT_BUS_NAME=smartops-local \
    --set env.AWS_REGION=us-east-1 \
    --wait --timeout 90s \
    || die "controller helm install failed — inspect: kubectl -n ${CTRL_NAMESPACE} describe pods"
  ok "helm release '${CTRL_RELEASE}' ready (DRY_RUN mode — no AWS calls)"
fi

# ---- 9. Show status ----------------------------------------------------
say "cluster status"
kubectl get nodes -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,STATUS:.status.conditions[?\(@.type==\"Ready\"\)].status
echo ""
kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/instance=${RELEASE}" \
  -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,PHASE:.status.phase
if kubectl get ns "${CTRL_NAMESPACE}" >/dev/null 2>&1; then
  echo ""
  kubectl -n "${CTRL_NAMESPACE}" get pods -l "app.kubernetes.io/instance=${CTRL_RELEASE}" \
    -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,PHASE:.status.phase 2>/dev/null || true
fi

# ---- 10. Next steps ----------------------------------------------------
echo ""
say "next steps"
cat <<EOF
  export KUBECONFIG=${KUBECONFIG_PATH}

  # Port-forward crashy-app to your laptop:
  kubectl -n ${NAMESPACE} port-forward svc/${RELEASE}-crashy-app 18080:80 &
  curl http://localhost:18080/            # pod/node/zone identity
  curl http://localhost:18080/healthz     # 200 OK
  kill %1

  # Or drive it via chaos.sh:
  KUBECONFIG=${KUBECONFIG_PATH} bash scripts/chaos.sh info
  KUBECONFIG=${KUBECONFIG_PATH} bash scripts/chaos.sh spread
  KUBECONFIG=${KUBECONFIG_PATH} bash scripts/chaos.sh crash

  # Watch the controller pick up the incident (dry-run: logs to stdout):
  KUBECONFIG=${KUBECONFIG_PATH} kubectl -n ${CTRL_NAMESPACE} logs -l app.kubernetes.io/instance=${CTRL_RELEASE} -f

  # When done:
  make local-down                          # tears everything down
EOF
