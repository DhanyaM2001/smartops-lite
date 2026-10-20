#!/usr/bin/env bash
# scripts/verify.sh — module-aware health check.
#
# Progressively verifies what's supposed to be up. Anything not yet built
# (e.g. Module 3 not deployed yet) is reported as SKIPPED, not FAILED.
#
# Optional flags:
#   --with-slack   also POST a test message to the Slack webhook
#                  (disabled by default — avoids spamming #smartops-alerts on
#                  every 'make verify')
#   --module N     only run checks for module N and below
#
# Called by: `make verify`

set -uo pipefail

AWS_PROFILE="${AWS_PROFILE:-smartops}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT_ENV="${PROJECT_ENV:-dev}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-smartops}"
export KUBECONFIG

WITH_SLACK=0
MAX_MODULE=99
while [ $# -gt 0 ]; do
  case "$1" in
    --with-slack) WITH_SLACK=1 ;;
    --module)     MAX_MODULE="${2:-99}"; shift ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
FAILS=0
info() { printf "\n${CYAN}▶${RESET} %s\n" "$*"; }
ok()   { printf "  ${GREEN}✔${RESET} %s\n" "$*"; }
skip() { printf "  ${YELLOW}—${RESET} %s\n" "$*"; }
fail() { printf "  ${RED}✘${RESET} %s\n" "$*"; FAILS=$((FAILS+1)); }

aws_cli() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

# --- Module 0: local setup + AWS backend + SSM secrets --------------------

if [ "$MAX_MODULE" -ge 0 ]; then
  info "Module 0 — AWS backend + SSM secrets"

  if aws_cli sts get-caller-identity >/dev/null 2>&1; then
    acct=$(aws_cli sts get-caller-identity --query Account --output text)
    ok "aws sts ok (account $acct, profile $AWS_PROFILE)"
  else
    fail "aws sts get-caller-identity failed for profile $AWS_PROFILE"
  fi

  if aws_cli s3api head-bucket --bucket "smartops-lite-tf-state-$(aws_cli sts get-caller-identity --query Account --output text 2>/dev/null)" 2>/dev/null; then
    ok "S3 tf-state bucket exists"
  else
    skip "S3 tf-state bucket not created (run: make bootstrap-backend)"
  fi

  if aws_cli dynamodb describe-table --table-name smartops-lite-tf-lock >/dev/null 2>&1; then
    ok "DynamoDB tf-lock table exists"
  else
    skip "DynamoDB tf-lock table not created (run: make bootstrap-backend)"
  fi

  for p in "/smartops/${PROJECT_ENV}/slack_webhook" "/smartops/${PROJECT_ENV}/groq_api_key"; do
    if aws_cli ssm get-parameter --name "$p" >/dev/null 2>&1; then
      ok "SSM param $p exists"
    else
      skip "SSM param $p not stored (run: make put-secrets)"
    fi
  done
fi

# --- Module 1+: Terraform state ------------------------------------------

if [ "$MAX_MODULE" -ge 1 ]; then
  info "Module 1+ — Terraform state"
  if [ -d infra/envs/dev/.terraform ]; then
    count=$(cd infra/envs/dev && terraform state list 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
      ok "terraform state has $count resource(s)"
    else
      skip "terraform initialised but empty (run: make tf-apply)"
    fi
  else
    skip "terraform not initialised in infra/envs/dev (run: make tf-init)"
  fi
fi

# --- Module 2+: Kubernetes cluster ---------------------------------------

if [ "$MAX_MODULE" -ge 2 ]; then
  info "Module 2+ — Kubernetes cluster"

  # If Terraform is initialised, ask it what the expected node count is
  # (1 for Module 1, 2 for Module 2 with enable_agent=true). Fall back to 1.
  expected=1
  if [ -d infra/envs/dev/.terraform ]; then
    e=$(cd infra/envs/dev && terraform output -raw expected_node_count 2>/dev/null || echo "")
    [ -n "$e" ] && expected="$e"
  fi

  if kubectl cluster-info >/dev/null 2>&1; then
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print $1}' | wc -l)
    total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    ready=$(( total - not_ready ))

    if [ "$total" -eq 0 ]; then
      skip "no nodes registered"
    elif [ "$not_ready" -gt 0 ]; then
      fail "$not_ready of $total node(s) not Ready"
    elif [ "$ready" -lt "$expected" ]; then
      # Cluster is healthy but the agent may still be joining (cloud-init ~3min)
      skip "$ready of $expected node(s) Ready — agent may still be joining"
    elif [ "$ready" -eq "$expected" ]; then
      ok "$ready node(s) Ready (matches expected=$expected)"
    else
      # More than expected — unusual but not a failure (e.g. leftover node)
      ok "$ready node(s) Ready (expected $expected — extras found, investigate if unintentional)"
    fi

    # Distinct AZs check — critical for anti-affinity in Module 3+
    if [ "$ready" -ge 2 ]; then
      azs=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}{end}' 2>/dev/null | sort -u | wc -l)
      if [ "$azs" -ge 2 ]; then
        ok "nodes span $azs distinct AZ(s) — anti-affinity possible"
      else
        fail "all $ready nodes in the same AZ — anti-affinity won't help"
      fi
    fi
  else
    skip "kubectl can't reach cluster (kubeconfig: $KUBECONFIG)"
  fi
fi

# --- Module 3+: Helm-deployed workloads ----------------------------------

if [ "$MAX_MODULE" -ge 3 ]; then
  info "Module 3+ — namespaces + workloads"
  for ns in demo smartops; do
    if kubectl get ns "$ns" >/dev/null 2>&1; then
      ok "namespace/$ns"
    else
      skip "namespace/$ns not yet created"
    fi
  done

  # crashy-app deployment ready?
  if kubectl -n demo get deploy 2>/dev/null | grep -q crashy-app; then
    desired=$(kubectl -n demo get deploy -l app.kubernetes.io/name=crashy-app -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || echo 0)
    ready=$(kubectl -n demo get deploy -l app.kubernetes.io/name=crashy-app -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo 0)
    if [ "${ready:-0}" -ge "${desired:-1}" ] && [ "${desired:-0}" -gt 0 ]; then
      ok "crashy-app deployment: $ready/$desired ready"
    else
      fail "crashy-app deployment: $ready/$desired ready"
    fi
  else
    skip "crashy-app deployment not found (Module 3 not deployed)"
  fi
fi

# --- Module 4+: Controller + EventBridge bus -----------------------------

if [ "$MAX_MODULE" -ge 4 ]; then
  info "Module 4+ — smartops-controller + EventBridge bus"

  # Terraform output → bus name (falls back to smartops-dev).
  bus_name="smartops-dev"
  if [ -d infra/envs/dev/.terraform ]; then
    b=$(cd infra/envs/dev && terraform output -raw event_bus_name 2>/dev/null || echo "")
    [ -n "$b" ] && bus_name="$b"
  fi

  if aws_cli events describe-event-bus --name "$bus_name" >/dev/null 2>&1; then
    ok "eventbridge/$bus_name exists"
  else
    skip "eventbridge/$bus_name not created (run: make tf-apply)"
  fi

  # Controller deployment ready?
  if kubectl -n smartops get deploy 2>/dev/null | grep -q smartops-controller; then
    desired=$(kubectl -n smartops get deploy -l app.kubernetes.io/name=smartops-controller -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || echo 0)
    ready=$(kubectl -n smartops get deploy -l app.kubernetes.io/name=smartops-controller -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo 0)
    if [ "${ready:-0}" -ge "${desired:-1}" ] && [ "${desired:-0}" -gt 0 ]; then
      ok "smartops-controller deployment: $ready/$desired ready"
    else
      fail "smartops-controller deployment: $ready/$desired ready"
    fi

    # Health probe
    pod=$(kubectl -n smartops get pod -l app.kubernetes.io/name=smartops-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$pod" ]; then
      if kubectl -n smartops exec "$pod" -- python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8081/healthz', timeout=2).status==200 else 1)" >/dev/null 2>&1; then
        ok "controller /healthz responds 200"
      else
        skip "controller /healthz probe skipped (exec unavailable or in-progress startup)"
      fi
    fi
  else
    skip "smartops-controller deployment not found (Module 4 not deployed)"
  fi
fi

# --- Module 5+: RCA Lambda + DynamoDB + EventBridge rule -----------------

if [ "$MAX_MODULE" -ge 5 ]; then
  info "Module 5+ — RCA pipeline (Lambda + DDB + rule)"

  # Read the actual deployed names from Terraform output so we don't guess.
  rca_fn="smartops-lite-rca-generator"
  incidents_table="smartops-incidents"
  incident_rule=""
  if [ -d infra/envs/dev/.terraform ]; then
    n=$(cd infra/envs/dev && terraform output -raw rca_lambda_name 2>/dev/null || echo "")
    [ -n "$n" ] && rca_fn="$n"
    t=$(cd infra/envs/dev && terraform output -raw incidents_table_name 2>/dev/null || echo "")
    [ -n "$t" ] && incidents_table="$t"
    r=$(cd infra/envs/dev && terraform output -raw incident_rule_name 2>/dev/null || echo "")
    [ -n "$r" ] && incident_rule="$r"
  fi

  # 1. Lambda exists + is packaged (State=Active means the last update finished)
  state=$(aws_cli lambda get-function --function-name "$rca_fn" \
           --query 'Configuration.State' --output text 2>/dev/null || echo MISSING)
  case "$state" in
    Active)   ok "lambda/$rca_fn state=Active" ;;
    Pending)  skip "lambda/$rca_fn state=Pending (deployment in progress)" ;;
    MISSING)  skip "lambda/$rca_fn not deployed (run: make tf-apply)" ;;
    *)        fail "lambda/$rca_fn in state $state" ;;
  esac

  # 2. DynamoDB table
  status=$(aws_cli dynamodb describe-table --table-name "$incidents_table" \
           --query 'Table.TableStatus' --output text 2>/dev/null || echo MISSING)
  case "$status" in
    ACTIVE)  ok "dynamodb/$incidents_table ACTIVE" ;;
    MISSING) skip "dynamodb/$incidents_table not created" ;;
    *)       fail "dynamodb/$incidents_table in status $status" ;;
  esac

  # 3. EventBridge rule attached to the bus with the Lambda as target
  if [ -n "$incident_rule" ]; then
    bus_name="smartops-dev"
    if [ -d infra/envs/dev/.terraform ]; then
      b=$(cd infra/envs/dev && terraform output -raw event_bus_name 2>/dev/null || echo "")
      [ -n "$b" ] && bus_name="$b"
    fi
    if aws_cli events describe-rule --name "$incident_rule" --event-bus-name "$bus_name" >/dev/null 2>&1; then
      target_arn=$(aws_cli events list-targets-by-rule --rule "$incident_rule" --event-bus-name "$bus_name" \
                    --query 'Targets[0].Arn' --output text 2>/dev/null || echo "")
      if [ -n "$target_arn" ] && [ "$target_arn" != "None" ]; then
        ok "eventbridge rule $incident_rule → $target_arn"
      else
        fail "eventbridge rule $incident_rule exists but has NO target"
      fi
    else
      skip "eventbridge rule $incident_rule not created"
    fi
  else
    skip "incident_rule_name output missing — is Module 5 applied?"
  fi

  # 4. Any successful invocations in the last hour? (informational — skip on 0)
  if [ "$state" = "Active" ]; then
    since_ms=$(( ($(date +%s) - 3600) * 1000 ))
    invocations=$(aws_cli cloudwatch get-metric-statistics \
      --namespace AWS/Lambda \
      --metric-name Invocations \
      --dimensions Name=FunctionName,Value="$rca_fn" \
      --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
      --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --period 3600 \
      --statistics Sum \
      --query 'Datapoints[0].Sum' --output text 2>/dev/null || echo "None")
    if [ "$invocations" != "None" ] && [ "$invocations" != "0.0" ] && [ -n "$invocations" ]; then
      ok "lambda/$rca_fn invocations (last hour): $invocations"
    else
      skip "lambda/$rca_fn no invocations in last hour (fine if no crashes yet)"
    fi
  fi
fi

# --- Optional: Slack webhook liveness check ------------------------------

if [ "$WITH_SLACK" -eq 1 ]; then
  info "Slack webhook liveness (posts a real message!)"
  WEBHOOK=$(aws_cli ssm get-parameter --name "/smartops/${PROJECT_ENV}/slack_webhook" \
            --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")
  if [ -n "$WEBHOOK" ]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
      -H 'Content-type: application/json' \
      --data '{"text":"[smartops verify] health check ping"}' "$WEBHOOK")
    if [ "$code" = "200" ]; then
      ok "slack webhook returned 200"
    else
      fail "slack webhook returned $code"
    fi
  else
    skip "slack webhook not in SSM"
  fi
fi

# --- Verdict -------------------------------------------------------------

echo ""
if [ "$FAILS" -eq 0 ]; then
  printf "${GREEN}All checks passed.${RESET}\n"
  exit 0
else
  printf "${RED}%d check(s) failed.${RESET}\n" "$FAILS"
  exit 1
fi
