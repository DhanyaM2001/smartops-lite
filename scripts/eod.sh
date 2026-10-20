#!/usr/bin/env bash
# scripts/eod.sh — End Of Day: safely destroy every "billable" resource in the
# right order, but leave the *permanent* infra alone (S3 tf-state bucket,
# DynamoDB tf-lock, SSM secrets, IAM users).
#
# Module-aware: skips gracefully whenever a layer doesn't exist yet.
#
# Order (matters — bottom-up, opposite of `make up`):
#   1) helm uninstall  (Module 3+ workloads)
#   2) terraform destroy on infra/envs/dev (Module 1+ AWS resources)
#   3) local kubeconfig cleanup
#   4) check-orphans.sh  (final safety net)
#
# Env:
#   AWS_PROFILE  (default smartops)
#   AWS_REGION   (default ap-south-1)
#   ENV          (default dev)
#
# Usage:
#   bash scripts/eod.sh              # interactive (asks "yes" before destroy)
#   bash scripts/eod.sh --yes        # non-interactive (for cron / muscle-memory)

set -uo pipefail

AWS_PROFILE="${AWS_PROFILE:-smartops}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
ENV_="${ENV:-dev}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-smartops}"

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "  ${GREEN}✔${RESET} %s\n" "$*"; }
skip() { printf "  ${YELLOW}—${RESET} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }

ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
  shift
done

if [ "$ASSUME_YES" -eq 0 ]; then
  cat <<EOF
─────────────────────────────────────────────────────────────
End-Of-Day teardown
─────────────────────────────────────────────────────────────
  Profile:   $AWS_PROFILE
  Region:    $AWS_REGION
  Env:       $ENV_
  Kubeconfig: $KUBECONFIG

Will destroy: all Helm releases, all Terraform-managed AWS resources
              (EC2, EBS, VPC, Lambda, IAM roles, etc.).
Will KEEP:    S3 tf-state bucket, DynamoDB tf-lock, SSM secrets, IAM CLI user.
              (Use 'make nuke' at project retirement to delete those too.)
─────────────────────────────────────────────────────────────
EOF
  read -rp "Proceed? [type YES to continue]: " ans
  [ "$ans" = "YES" ] || { echo "aborted."; exit 0; }
fi

# ---- 1. Helm uninstall ---------------------------------------------------

say "1/4  Helm uninstall"
if [ -f "$KUBECONFIG" ] && command -v helm >/dev/null 2>&1 && \
   KUBECONFIG="$KUBECONFIG" kubectl cluster-info >/dev/null 2>&1; then
  for spec in "app:demo" "ctrl:smartops"; do
    rel="${spec%%:*}"; ns="${spec##*:}"
    if KUBECONFIG="$KUBECONFIG" helm status "$rel" -n "$ns" >/dev/null 2>&1; then
      KUBECONFIG="$KUBECONFIG" helm uninstall "$rel" -n "$ns" >/dev/null && ok "helm/$rel"
    else
      skip "helm/$rel (not installed)"
    fi
  done
else
  skip "cluster not reachable — nothing to uninstall"
fi

# ---- 2. Terraform destroy -----------------------------------------------

say "2/4  Terraform destroy (infra/envs/$ENV_)"
TF_DIR="infra/envs/$ENV_"
if [ -d "$TF_DIR/.terraform" ]; then
  ( cd "$TF_DIR" && \
    AWS_PROFILE="$AWS_PROFILE" AWS_REGION="$AWS_REGION" \
    terraform destroy -auto-approve ) && ok "terraform destroy complete" \
    || warn "terraform destroy had errors — inspect above"
elif [ -d "$TF_DIR" ]; then
  skip "terraform not initialised in $TF_DIR (nothing to destroy)"
else
  skip "$TF_DIR doesn't exist yet (Module 1 hasn't run)"
fi

# ---- 3. Local kubeconfig cleanup ----------------------------------------

say "3/4  Local kubeconfig cleanup"
if [ -f "$KUBECONFIG" ]; then
  rm -f "$KUBECONFIG" && ok "removed $KUBECONFIG"
else
  skip "no kubeconfig at $KUBECONFIG"
fi

# ---- 4. Orphan check ----------------------------------------------------

say "4/4  Orphan check (billable resources still present?)"
AWS_PROFILE="$AWS_PROFILE" AWS_REGION="$AWS_REGION" \
  bash "$(dirname "$0")/check-orphans.sh"
orphan_rc=$?

echo ""
if [ "$orphan_rc" -eq 0 ]; then
  printf "${GREEN}EOD complete — safe to close laptop.${RESET}\n"
else
  printf "${RED}EOD finished but orphans found — see above.${RESET}\n"
  echo "   Try again, or use 'bash scripts/teardown.sh' for nuclear cleanup."
  exit 1
fi
