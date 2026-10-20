#!/usr/bin/env bash
# scripts/demo.sh — scripted end-to-end demo runner for the Loom video.
#
# What it does (in order):
#   1. Pre-flight — verify kubectl, aws, secrets, deployment health.
#   2. Baseline — show 2 healthy pods across 2 zones.
#   3. Chaos — trigger CrashLoopBackOff on one replica.
#   4. Show the pipeline reacting — controller logs + Slack ping delay.
#   5. Verify persistence — DDB row landed with the RCA text.
#   6. Force-refresh metrics — invoke the MTTR aggregator now (bypass 5-min tick).
#   7. Show the CloudWatch metrics that Grafana reads.
#   8. Print the Grafana dashboard URL.
#   9. Print the current-month AWS spend.
#
# Modes:
#   scripts/demo.sh                    → full demo (~90 s)
#   scripts/demo.sh --dry-run          → same output but skips chaos + AWS mutations (rehearse)
#   scripts/demo.sh --reset            → roll crashy-app back to healthy replicas + exit
#   scripts/demo.sh --skip-preflight   → skip the check-everything block (for CI use)
#
# Env vars (all optional):
#   NAMESPACE   (default: demo)
#   RELEASE     (default: app)                     — Helm release name for crashy-app
#   KUBECONFIG  (default: ~/.kube/config-smartops)
#   REGION      (default: value in `aws configure get region`)
#   TF_DIR      (default: infra/envs/dev)
#   SHOW_COST   (default: false)                   — query Cost Explorer ($0.01/request)
#   PAUSE_SHORT / PAUSE_MED / PAUSE_LONG           — banner delays (seconds)
#
# Idempotent — safe to re-run.

set -uo pipefail

# ---- config -------------------------------------------------------------
NS="${NAMESPACE:-demo}"
RELEASE="${RELEASE:-app}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-smartops}"
TF_DIR="${TF_DIR:-infra/envs/dev}"
REGION="${REGION:-$(aws configure get region 2>/dev/null || echo ap-south-1)}"
PAUSE_SHORT="${PAUSE_SHORT:-2}"
PAUSE_MED="${PAUSE_MED:-4}"
PAUSE_LONG="${PAUSE_LONG:-10}"
export KUBECONFIG

DRY_RUN=false
RESET_MODE=false
SKIP_PREFLIGHT=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=true ;;
    --reset)          RESET_MODE=true ;;
    --skip-preflight) SKIP_PREFLIGHT=true ;;
    -h|--help)
      sed -n '2,32p' "$0"; exit 0 ;;
    *)
      echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

SELECTOR="app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/name=crashy-app"
DEPLOY_NAME="${RELEASE}-crashy-app"

# ---- pretty printing ----------------------------------------------------
CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; MAG='\033[35m'; RESET='\033[0m'
banner() { printf "\n\033[46;30m %s \033[0m\n" "$*"; }
step()   { printf "${CYAN}==>${RESET} ${MAG}%s${RESET}\n" "$*"; }
ok()     { printf "${GREEN}\xe2\x9c\x94${RESET} %s\n" "$*"; }
warn()   { printf "${YELLOW}!${RESET} %s\n" "$*"; }
die()    { printf "${RED}\xe2\x9c\x98${RESET} %s\n" "$*" >&2; exit 1; }
pause()  { $DRY_RUN && return 0; sleep "${1:-$PAUSE_SHORT}"; }

# ---- output helpers -----------------------------------------------------
# Grab a terraform output, fallback to a default (dev-mode).
tf_out() {
  local name="$1" default="${2:-}"
  local v
  v="$(cd "$TF_DIR" 2>/dev/null && terraform output -raw "$name" 2>/dev/null || true)"
  echo "${v:-$default}"
}

# ---- --reset mode: put the cluster back into a healthy state ------------
if $RESET_MODE; then
  banner "reset — rolling crashy-app back to a healthy state"
  step "helm rollback ${RELEASE} to latest revision (heals any pending crash)"
  if kubectl -n "$NS" rollout restart "deploy/$DEPLOY_NAME" 2>/dev/null; then
    step "waiting up to 90s for rollout to complete"
    kubectl -n "$NS" rollout status "deploy/$DEPLOY_NAME" --timeout=90s || warn "rollout not ready in 90s"
  else
    warn "deployment $DEPLOY_NAME not found — nothing to reset (is crashy-app installed?)"
  fi
  step "current pod state:"
  kubectl -n "$NS" get pods -l "$SELECTOR" \
    -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
  ok "reset complete"
  exit 0
fi

# ---- pre-flight ---------------------------------------------------------
if ! $SKIP_PREFLIGHT; then
  banner "pre-flight checks"
  ERRORS=0
  step "kubectl reachable"
  kubectl version --request-timeout=5s -o json >/dev/null 2>&1 \
    && ok "cluster reachable" \
    || { warn "cluster NOT reachable — is your SSM tunnel open?"; ERRORS=$((ERRORS+1)); }

  step "crashy-app deployment present"
  kubectl -n "$NS" get deploy "$DEPLOY_NAME" >/dev/null 2>&1 \
    && ok "$DEPLOY_NAME present" \
    || { warn "$DEPLOY_NAME missing — run 'make helm-install-crashy'"; ERRORS=$((ERRORS+1)); }

  step "AWS credentials"
  if command -v aws >/dev/null 2>&1; then
    aws sts get-caller-identity >/dev/null 2>&1 \
      && ok "aws sts OK ($(aws sts get-caller-identity --query Account --output text 2>/dev/null))" \
      || { warn "aws sts failed — run 'aws configure' or export AWS_PROFILE"; ERRORS=$((ERRORS+1)); }
  else
    warn "aws CLI not installed — skipping cost + metrics steps"
  fi

  step "Slack webhook secret set (SSM)"
  if aws ssm get-parameter --name "/smartops/dev/slack_webhook" --with-decryption \
        --region "$REGION" --query 'Parameter.Value' --output text >/dev/null 2>&1; then
    ok "slack webhook in SSM"
  else
    warn "/smartops/dev/slack_webhook missing — run 'make put-secrets'"
    ERRORS=$((ERRORS+1))
  fi

  step "Groq key secret set (SSM)"
  if aws ssm get-parameter --name "/smartops/dev/groq_api_key" --with-decryption \
        --region "$REGION" --query 'Parameter.Value' --output text >/dev/null 2>&1; then
    ok "groq key in SSM"
  else
    warn "/smartops/dev/groq_api_key missing — RCA will fall back to placeholder text"
  fi

  if [ "$ERRORS" -gt 0 ]; then
    die "$ERRORS pre-flight error(s). Fix them or re-run with --skip-preflight to bypass."
  fi
  pause "$PAUSE_SHORT"
fi

# ==========================================================================
banner "[00:00] SmartOps-Lite — end-to-end demo"
pause "$PAUSE_SHORT"

# --------------------------------------------------------------------------
banner "[00:03] baseline — 2 replicas spread across 2 zones"
step "chaos.sh spread"
if $DRY_RUN; then
  echo "  (dry-run) skipping"
else
  bash "$(dirname "$0")/chaos.sh" spread || true
fi
pause "$PAUSE_MED"

# --------------------------------------------------------------------------
banner "[00:10] triggering CrashLoopBackOff on one replica"
step "chaos.sh crash"
if $DRY_RUN; then
  echo "  (dry-run) skipping"
else
  bash "$(dirname "$0")/chaos.sh" crash || true
fi
pause "$PAUSE_MED"

# --------------------------------------------------------------------------
banner "[00:20] watching pod state (10 s window)"
if $DRY_RUN; then
  echo "  (dry-run) skipping"
else
  timeout 10 kubectl -n "$NS" get pods -l "$SELECTOR" -w || true
fi
pause "$PAUSE_SHORT"

# --------------------------------------------------------------------------
banner "[00:35] Slack ⇒ #smartops-alerts should now show the Block Kit RCA card"
echo "    • color-coded severity (red = crash, orange = OOM, ...)"
echo "    • 2-sentence Groq-generated RCA"
echo "    • 'Acknowledge' button routes to the remediator Lambda"
step "give Slack + LLM ~10 s to land"
pause "$PAUSE_LONG"

# --------------------------------------------------------------------------
banner "[00:45] verify DDB — the last incident should be persisted"
TABLE="$(tf_out incidents_table_name "smartops-incidents")"
if $DRY_RUN; then
  echo "  (dry-run) skipping"
elif command -v aws >/dev/null 2>&1; then
  step "aws dynamodb scan $TABLE (latest incident)"
  aws dynamodb scan --table-name "$TABLE" --region "$REGION" \
    --query 'reverse(sort_by(Items, &ingestedAt.S))[0].[incidentId.S, reason.S, podName.S, rcaSource.S, rcaStatus.S]' \
    --output table 2>/dev/null \
    || warn "table $TABLE not reachable yet"
else
  warn "aws CLI missing — skipping DDB check"
fi
pause "$PAUSE_MED"

# --------------------------------------------------------------------------
banner "[00:55] force-refresh dashboard metrics (bypass 5-min schedule)"
FN="$(tf_out mttr_aggregator_lambda_name "smartops-lite-mttr-aggregator")"
if $DRY_RUN; then
  echo "  (dry-run) skipping"
elif command -v aws >/dev/null 2>&1; then
  step "aws lambda invoke $FN with synthetic Scheduled Event"
  TMP="$(mktemp)"
  if aws lambda invoke --function-name "$FN" --region "$REGION" \
       --cli-binary-format raw-in-base64-out \
       --payload "{\"source\":\"aws.events\",\"detail-type\":\"Scheduled Event\",\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
       "$TMP" >/dev/null 2>&1; then
    step "aggregator response:"
    cat "$TMP" && echo ""
  else
    warn "lambda invoke failed (function $FN may not exist yet — run make tf-apply)"
  fi
  rm -f "$TMP"
fi
pause "$PAUSE_MED"

# --------------------------------------------------------------------------
banner "[01:05] CloudWatch metrics (the 5 series Grafana renders)"
NAMESPACE_CW="$(tf_out mttr_metric_namespace "SmartOps")"
if $DRY_RUN; then
  echo "  (dry-run) skipping"
elif command -v aws >/dev/null 2>&1; then
  step "aws cloudwatch list-metrics --namespace $NAMESPACE_CW"
  aws cloudwatch list-metrics --namespace "$NAMESPACE_CW" --region "$REGION" \
    --query 'Metrics[*].[MetricName]' --output table 2>/dev/null \
    || warn "no metrics yet — schedule may need one more tick"
fi
pause "$PAUSE_MED"

# --------------------------------------------------------------------------
banner "[01:15] Grafana dashboard"
echo "    → dashboards/grafana/mttr-dashboard.json"
echo "    → import into Grafana Cloud (free tier) — see dashboards/grafana/README.md"
step "MTTR trend chart + ack rate gauge + LLM success rate gauge should all light up"
pause "$PAUSE_MED"

# --------------------------------------------------------------------------
banner "[01:25] cost so far this month"
# Every Cost Explorer API request is billed at $0.01, so this step is opt-in.
if $DRY_RUN; then
  echo "  (dry-run) skipping"
elif [ "${SHOW_COST:-false}" != "true" ]; then
  echo "    → skipped (SHOW_COST=true to query Cost Explorer; \$0.01 per request)"
  echo "    → free alternative: AWS console → Billing and Cost Management → Free Tier"
elif command -v aws >/dev/null 2>&1; then
  amt="$(aws ce get-cost-and-usage \
          --time-period Start="$(date +%Y-%m-01)",End="$(date +%F)" \
          --granularity MONTHLY --metrics UnblendedCost \
          --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text 2>/dev/null || true)"
  if [ -n "$amt" ] && [ "$amt" != "None" ]; then
    printf "    → \$%.4f USD (target: \$0 within free tier)\n" "$amt"
  else
    echo "    → Cost Explorer not enabled yet (new AWS accounts take a week)"
  fi
fi
pause "$PAUSE_SHORT"

# --------------------------------------------------------------------------
banner "[01:30] done."
ok "end-to-end pipeline verified: chaos → controller → EventBridge → Lambda → Groq → DDB → Slack → CloudWatch → Grafana"
echo "    to reset the cluster to a healthy state: scripts/demo.sh --reset"
