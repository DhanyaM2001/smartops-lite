#!/usr/bin/env bash
# .devcontainer/postCreate.sh — runs ONCE after the devcontainer is created.
#
# Verifies every CLI is installed + prints a welcome banner with next steps.
# Kept in a script (not inline in devcontainer.json) so it's easy to iterate.

set -uo pipefail

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
FAILS=0

check() {
  local name="$1"; shift
  local cmd="$*"
  if version=$(eval "$cmd" 2>/dev/null | head -n1); then
    printf "  ${GREEN}\xe2\x9c\x94${RESET} %-14s %s\n" "$name" "$version"
  else
    printf "  ${RED}\xe2\x9c\x98${RESET} %-14s MISSING\n" "$name"
    FAILS=$((FAILS+1))
  fi
}

echo -e "\n${CYAN}==> Verifying dev container toolchain${RESET}\n"

check "aws"        "aws --version"
check "terraform"  "terraform version"
check "kubectl"    "kubectl version --client 2>/dev/null | head -n1"
check "helm"       "helm version --short"
check "kind"       "kind version"
check "docker"     "docker --version"
check "gh"         "gh --version | head -n1"
check "python"     "python3 --version"
check "poetry"     "poetry --version 2>/dev/null || pipx run poetry --version"
check "jq"         "jq --version"
check "yq"         "yq --version"
check "make"       "make --version | head -n1"
check "git"        "git --version"

echo ""
if [ "$FAILS" -gt 0 ]; then
  echo -e "${RED}${FAILS} tool(s) missing — the container is not fully ready.${RESET}"
  exit 1
fi

# ---- Welcome banner ------------------------------------------------------
cat <<'BANNER'

┌───────────────────────────────────────────────────────────────────────┐
│                                                                       │
│    SmartOps-Lite — Dev Container is ready.                            │
│                                                                       │
│    Two paths from here:                                               │
│                                                                       │
│    A. Local-only demo (no AWS account needed)                         │
│       $ make local-up            # kind cluster + crashy-app (~3 min) │
│       $ make chaos-spread        # verify pods spread across zones    │
│       $ make chaos-crash         # trigger a CrashLoopBackOff         │
│       $ make local-down          # tear it all down                   │
│                                                                       │
│    B. Real AWS demo (free-tier eligible)                              │
│       $ aws configure --profile smartops                              │
│       $ make bootstrap-backend   # S3 state bucket + DDB lock         │
│       $ make put-secrets         # Slack + Groq keys -> SSM           │
│       then: docs/INSTALL.md section 5 (deploy, demo, teardown)        │
│       $ make eod                 # END-OF-DAY teardown (ALWAYS run)   │
│                                                                       │
│    Quick reference:                                                   │
│       $ make help                # every target with a one-liner      │
│       $ kubectl get pods -A      # what's running in the cluster      │
│                                                                       │
│    Full docs:                                                         │
│       docs/INSTALL.md            (install & deploy on any system)     │
│       docs/REFERENCE.md          (encyclopedia of every script)       │
│                                                                       │
└───────────────────────────────────────────────────────────────────────┘

BANNER
