#!/usr/bin/env bash
# scripts/status.sh — one-glance view of what's currently running.
#
# Called by 'make status'. Purely read-only; never mutates AWS or cluster.

set -uo pipefail

AWS_PROFILE="${AWS_PROFILE:-smartops}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT_ENV="${PROJECT_ENV:-dev}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-smartops}"

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RESET='\033[0m'
hdr() { printf "\n${CYAN}▶ %s${RESET}\n" "$*"; }
kv()  { printf "  %-16s %s\n" "$1" "$2"; }

aws_cli() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

hdr "Identity"
if aws_cli sts get-caller-identity >/dev/null 2>&1; then
  kv "profile"  "$AWS_PROFILE"
  kv "region"   "$AWS_REGION"
  kv "account"  "$(aws_cli sts get-caller-identity --query Account --output text)"
  kv "arn"      "$(aws_cli sts get-caller-identity --query Arn --output text)"
else
  kv "profile"  "$AWS_PROFILE (${YELLOW}unauthenticated${RESET})"
fi

hdr "Cost (current calendar month, unblended)"
first=$(date +%Y-%m-01 2>/dev/null || date -v1d +%Y-%m-%d)
today=$(date +%F)
cost=$(aws_cli ce get-cost-and-usage \
  --time-period "Start=$first,End=$today" \
  --granularity MONTHLY --metrics UnblendedCost \
  --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text 2>/dev/null || echo "?")
kv "so far" "\$${cost}"

hdr "Terraform backend (permanent shared infra)"
acct=$(aws_cli sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -n "$acct" ]; then
  bucket="smartops-lite-tf-state-$acct"
  if aws_cli s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    kv "s3 bucket" "$bucket ${GREEN}✔${RESET}"
  else
    kv "s3 bucket" "$bucket ${YELLOW}not created${RESET}"
  fi
  if aws_cli dynamodb describe-table --table-name smartops-lite-tf-lock >/dev/null 2>&1; then
    kv "ddb lock" "smartops-lite-tf-lock ${GREEN}✔${RESET}"
  else
    kv "ddb lock" "smartops-lite-tf-lock ${YELLOW}not created${RESET}"
  fi
fi

hdr "SSM secrets (permanent shared infra)"
for p in "/smartops/${PROJECT_ENV}/slack_webhook" "/smartops/${PROJECT_ENV}/groq_api_key"; do
  if aws_cli ssm get-parameter --name "$p" >/dev/null 2>&1; then
    mod=$(aws_cli ssm get-parameter --name "$p" --query 'Parameter.LastModifiedDate' --output text 2>/dev/null || echo "")
    kv "$(basename "$p")" "${GREEN}stored${RESET} (last updated: $mod)"
  else
    kv "$(basename "$p")" "${YELLOW}not stored${RESET}"
  fi
done

hdr "Terraform workload state (destroyed nightly)"
if [ -d infra/envs/dev/.terraform ]; then
  n=$(cd infra/envs/dev && terraform state list 2>/dev/null | wc -l)
  kv "resources"  "$n"
else
  kv "resources"  "0 (not initialised)"
fi

hdr "Kubernetes cluster (destroyed nightly)"
if [ -f "$KUBECONFIG" ] && KUBECONFIG="$KUBECONFIG" kubectl cluster-info >/dev/null 2>&1; then
  nodes=$(KUBECONFIG="$KUBECONFIG" kubectl get nodes --no-headers 2>/dev/null | wc -l)
  ready=$(KUBECONFIG="$KUBECONFIG" kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
  kv "nodes"   "$ready / $nodes Ready"
  pods=$(KUBECONFIG="$KUBECONFIG" kubectl get pods -A --no-headers 2>/dev/null | wc -l)
  kv "pods"    "$pods total across all namespaces"
else
  kv "cluster" "${YELLOW}not reachable${RESET}"
fi

hdr "Billable AWS resources (should be 0 or near-0 after 'make eod')"
inst=$(aws_cli ec2 describe-instances \
  --filters "Name=tag:project,Values=smartops-lite" "Name=instance-state-name,Values=running,pending" \
  --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)
vols=$(aws_cli ec2 describe-volumes \
  --filters "Name=tag:project,Values=smartops-lite" \
  --query 'length(Volumes)' --output text 2>/dev/null || echo 0)
lambs=$(aws_cli lambda list-functions \
  --query "length(Functions[?starts_with(FunctionName, 'smartops')])" --output text 2>/dev/null || echo 0)
kv "ec2 running"  "$inst"
kv "ebs volumes"  "$vols"
kv "lambdas"      "$lambs"

echo ""
