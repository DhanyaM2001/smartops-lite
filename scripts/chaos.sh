#!/usr/bin/env bash
# scripts/chaos.sh — trigger a specific failure mode against the crashy-app.
#
# Talks to the Kubernetes Service (not exec into pods) so the failure is
# distributed round-robin across replicas, and so it works without
# `kubectl exec` permissions.
#
# Usage:
#   scripts/chaos.sh crash                          → CrashLoopBackOff
#   scripts/chaos.sh oom                            → OOMKilled
#   scripts/chaos.sh error                          → 500 (app-level)
#   scripts/chaos.sh slow  [--ms 5000]              → latency injection
#   scripts/chaos.sh info                           → print pod/node/zone map
#   scripts/chaos.sh spread                         → verify pods are on different zones
#
# Env vars:
#   NAMESPACE   (default: demo)
#   RELEASE     (default: app)                     → the Helm release name
#   KUBECONFIG  (default: ~/.kube/config-smartops)
#   PORT_LOCAL  (default: 18080)                   → local port to port-forward to
#
# Requires: kubectl, curl. Uses a background kubectl port-forward while running.

set -euo pipefail

TYPE="${1:-}"
NS="${NAMESPACE:-demo}"
RELEASE="${RELEASE:-app}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-smartops}"
PORT_LOCAL="${PORT_LOCAL:-18080}"
export KUBECONFIG

# ---- helpers -------------------------------------------------------------
CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}\xe2\x9c\x94${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$*"; }
die()  { printf "${RED}\xe2\x9c\x98${RESET} %s\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 <command> [options]

Commands:
  crash              trigger CrashLoopBackOff (sends /crash to one replica)
  oom                trigger OOMKilled       (sends /oom  to one replica)
  error              trigger a 500          (sends /500  to one replica)
  slow [--ms N]      trigger latency        (sends /slow?ms=N; default N=5000)
  info               print each replica's pod / node / zone
  spread             assert replicas are spread across zones

Env: NAMESPACE=$NS  RELEASE=$RELEASE  KUBECONFIG=$KUBECONFIG  PORT_LOCAL=$PORT_LOCAL
EOF
}

case "$TYPE" in
  crash|oom|error|slow|info|spread) ;;
  ""|-h|--help|help) usage; exit 0 ;;
  *) usage; die "unknown command: $TYPE" ;;
esac

command -v kubectl >/dev/null 2>&1 || die "kubectl not found in PATH"
command -v curl    >/dev/null 2>&1 || die "curl not found in PATH"
[ -f "$KUBECONFIG" ] || die "kubeconfig not found at $KUBECONFIG — run 'make kube-config' first"

SELECTOR="app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/name=crashy-app"

# ---- discovery -----------------------------------------------------------
SVC="$(kubectl -n "$NS" get svc -l "$SELECTOR" \
       -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$SVC" ] || die "no crashy-app Service found in namespace '$NS' for release '$RELEASE'.
  Try: NAMESPACE=$NS  RELEASE=$RELEASE  or install first with 'make helm-install-crashy'."

# ---- info + spread -------------------------------------------------------
# Both commands need each pod's ACTUAL zone. The pod's own manifest doesn't
# carry that — the zone lives on the node it landed on
# (`topology.kubernetes.io/zone`). We join pods → nodes locally in awk so
# this stays kubectl-only (no cluster jq/jsonpath tricks).
print_pod_zone_table() {
  # 1. Pods → name, node
  local pods_tsv
  pods_tsv="$(kubectl -n "$NS" get pods -l "$SELECTOR" \
    -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase,READY:.status.containerStatuses[0].ready \
    --no-headers 2>/dev/null || true)"
  if [ -z "$pods_tsv" ]; then
    warn "no pods matched selector $SELECTOR in namespace $NS"
    return 1
  fi

  # 2. Nodes → name, zone (topology.kubernetes.io/zone label)
  local nodes_tsv
  nodes_tsv="$(kubectl get nodes \
    -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone \
    --no-headers 2>/dev/null || true)"

  # 3. Join in awk, keyed on node name.
  awk -v nodes="$nodes_tsv" '
    BEGIN {
      n = split(nodes, lines, "\n")
      for (i = 1; i <= n; i++) {
        split(lines[i], f, /[ \t]+/)
        if (f[1] != "") node_zone[f[1]] = (f[2] == "" ? "-" : f[2])
      }
      printf "%-38s %-24s %-10s %-8s %-7s\n", "POD", "NODE", "ZONE", "PHASE", "READY"
      printf "%-38s %-24s %-10s %-8s %-7s\n", "---", "----", "----", "-----", "-----"
    }
    {
      z = (node_zone[$2] != "" ? node_zone[$2] : "-")
      printf "%-38s %-24s %-10s %-8s %-7s\n", $1, $2, z, $3, $4
    }
  ' <<<"$pods_tsv"
}

if [ "$TYPE" = "info" ] || [ "$TYPE" = "spread" ]; then
  say "pods for release '$RELEASE' in namespace '$NS':"
  print_pod_zone_table || { die "pod discovery failed — cluster reachable? namespace/release correct?"; }

  if [ "$TYPE" = "spread" ]; then
    # Count distinct NODES and ZONES independently — a single-node
    # cluster (`enable_agent=false`) has 1 node ⇒ 1 zone which is fine
    # for a "preferred" affinity install but flags for a "required" one.
    NODES="$(kubectl -n "$NS" get pods -l "$SELECTOR" \
              -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null \
              | tr ' ' '\n' | sort -u | grep -c . || echo 0)"
    ZONE_LIST="$(kubectl -n "$NS" get pods -l "$SELECTOR" \
                  -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null \
                  | tr ' ' '\n' | sort -u \
                  | while read -r n; do
                      [ -z "$n" ] && continue
                      kubectl get node "$n" \
                        -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null
                      echo
                    done | sort -u | grep -c . || echo 0)"

    if [ "$ZONE_LIST" -ge 2 ]; then
      ok "pods spread across ${NODES} node(s) / ${ZONE_LIST} zone(s) — anti-affinity working"
    elif [ "$NODES" -ge 2 ]; then
      warn "pods on ${NODES} nodes but only ${ZONE_LIST} zone — nodes lack topology.kubernetes.io/zone labels"
    else
      warn "pods on ${NODES} node(s) only — either single-node cluster or anti-affinity is 'preferred'"
    fi
  fi
  exit 0
fi

# ---- port-forward for HTTP-based chaos ----------------------------------
say "starting kubectl port-forward svc/$SVC $PORT_LOCAL:80 (background)"
kubectl -n "$NS" port-forward "svc/$SVC" "$PORT_LOCAL:80" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 1.5   # give the tunnel a moment to establish

case "$TYPE" in
  crash)
    say "triggering /crash — expect CrashLoopBackOff shortly"
    curl -sS --max-time 3 "http://127.0.0.1:${PORT_LOCAL}/crash" || true
    ;;
  oom)
    say "triggering /oom — expect OOMKilled (memory limit is 128Mi)"
    curl -sS --max-time 30 "http://127.0.0.1:${PORT_LOCAL}/oom" || true
    ;;
  error)
    say "triggering /500"
    curl -sS -w '\nHTTP %{http_code}\n' "http://127.0.0.1:${PORT_LOCAL}/500" || true
    ;;
  slow)
    shift || true
    SLOW_MS=5000
    while [ $# -gt 0 ]; do
      case "$1" in
        --ms) SLOW_MS="$2"; shift 2 ;;
        *)    die "unknown option to 'slow': $1" ;;
      esac
    done
    say "triggering /slow?ms=$SLOW_MS"
    curl -sS -w '\nHTTP %{http_code}  time_total=%{time_total}s\n' \
      "http://127.0.0.1:${PORT_LOCAL}/slow?ms=${SLOW_MS}" || true
    ;;
esac

say "watch pod state:"
echo "  kubectl -n $NS get pods -l app.kubernetes.io/instance=$RELEASE -w"
