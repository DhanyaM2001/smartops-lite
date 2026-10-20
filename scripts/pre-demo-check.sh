#!/usr/bin/env bash
# scripts/pre-demo-check.sh — one-shot health check before recording the Loom.
#
# Verifies every dependency the demo script needs, then prints a green
# "ready" line or lists concrete fix commands. Purely read-only — makes
# ZERO changes to AWS or the cluster.
#
# Exit codes:
#   0 — all checks passed, safe to record
#   1 — at least one hard blocker (cluster/AWS/deploy)
#   2 — warnings only (dashboard/metrics not yet populated); demo will still work

set -uo pipefail

TF_DIR="${TF_DIR:-infra/envs/dev}"
NAMESPACE="${NAMESPACE:-demo}"
RELEASE="${RELEASE:-app}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-smartops}"
REGION="${REGION:-$(aws configure get region 2>/dev/null || echo ap-south-1)}"
DEPLOY_NAME="${RELEASE}-crashy-app"
SELECTOR="app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/name=crashy-app"
export KUBECONFIG

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
step() { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}\xe2\x9c\x94${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$*"; WARN=$((WARN+1)); }
fail() { printf "${RED}\xe2\x9c\x98${RESET} %s\n" "$*"; ERR=$((ERR+1)); }

ERR=0; WARN=0

banner() { printf "\n\033[46;30m %s \033[0m\n" "$*"; }

banner "Local toolchain"
for tool in kubectl aws terraform helm curl jq; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool ($(command -v "$tool"))"
  else
    if [ "$tool" = "jq" ] || [ "$tool" = "helm" ]; then
      warn "$tool missing (optional — some demo steps will skip)"
    else
      fail "$tool missing (install first: see docs/INSTALL.md)"
    fi
  fi
done

banner "AWS identity + region"
if aws sts get-caller-identity >/dev/null 2>&1; then
  ok "AWS account $(aws sts get-caller-identity --query Account --output text)"
  ok "region $REGION"
else
  fail "aws sts get-caller-identity failed — run 'aws configure' or export AWS_PROFILE"
fi

banner "Kubernetes cluster"
if kubectl version --request-timeout=5s -o json >/dev/null 2>&1; then
  ok "cluster reachable via $KUBECONFIG"
  NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || echo 0)"
  [ "$NODES" -ge 1 ] && ok "$NODES Ready node(s)" || fail "no Ready nodes"
else
  fail "kubectl unreachable — is your SSM tunnel to port 6443 open?"
  echo "    → make kube-config; make kube-api-tunnel (or the aws ssm start-session cmd)"
fi

banner "crashy-app deployment"
if kubectl -n "$NAMESPACE" get deploy "$DEPLOY_NAME" >/dev/null 2>&1; then
  RDY="$(kubectl -n "$NAMESPACE" get deploy "$DEPLOY_NAME" \
          -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo '?/?')"
  ok "$DEPLOY_NAME  (ready: $RDY)"
else
  fail "deployment $DEPLOY_NAME not found — run 'make helm-install-crashy'"
fi

banner "SSM secrets (SecureString)"
for path in /smartops/dev/slack_webhook /smartops/dev/groq_api_key /smartops/dev/slack_signing_secret; do
  if aws ssm get-parameter --name "$path" --with-decryption \
       --region "$REGION" --query 'Parameter.Value' --output text >/dev/null 2>&1; then
    ok "$path"
  else
    if [ "$path" = "/smartops/dev/slack_webhook" ] || [ "$path" = "/smartops/dev/groq_api_key" ]; then
      fail "$path missing — run 'make put-secrets'"
    else
      warn "$path missing (Module 7 ack button won't work; RCA still lands in DDB + Slack)"
    fi
  fi
done

banner "Terraform outputs (Modules 5/7/9)"
for out in incidents_table_name rca_lambda_name mttr_aggregator_lambda_name event_bus_name; do
  v="$(cd "$TF_DIR" 2>/dev/null && terraform output -raw "$out" 2>/dev/null || true)"
  if [ -n "$v" ]; then
    ok "$out = $v"
  else
    fail "$out missing — run 'make tf-apply' inside $TF_DIR"
  fi
done

banner "CloudWatch metrics populated?"
if aws cloudwatch list-metrics --namespace "SmartOps" --region "$REGION" \
     --query 'Metrics[0].MetricName' --output text 2>/dev/null | grep -qv None; then
  ok "SmartOps namespace has metrics (Grafana panels will render)"
else
  warn "no metrics in SmartOps namespace yet — run 'make invoke-mttr' before recording"
fi

banner "Summary"
echo "    errors:   $ERR"
echo "    warnings: $WARN"
if [ "$ERR" -gt 0 ]; then
  printf "${RED}\xe2\x9c\x98${RESET} not ready — fix the errors above then re-run.\n"
  exit 1
fi
if [ "$WARN" -gt 0 ]; then
  printf "${YELLOW}!${RESET} ready to record but some optional pieces are missing.\n"
  exit 2
fi
printf "${GREEN}\xe2\x9c\x94${RESET} all green — go record the Loom.\n"
exit 0
