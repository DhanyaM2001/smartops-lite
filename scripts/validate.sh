#!/usr/bin/env bash
# validate.sh — static validation without touching AWS or a cluster.
#
# Runs:
#   - terraform init -backend=false && terraform validate
#   - helm lint on every chart under helm/
#
# Safe to run offline. No AWS credentials required.
set -uo pipefail

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}\xe2\x9c\x94${RESET} %s\n" "$*"; }
skip() { printf "${YELLOW}\xe2\x8b\xaf${RESET} skip: %s\n" "$*"; }
fail() { printf "${RED}\xe2\x9c\x98${RESET} %s\n" "$*"; FAILED=1; }

FAILED=0
have() { command -v "$1" >/dev/null 2>&1; }
has_files() { [ -d "$1" ] && [ -n "$(find "$1" -type f ! -name '.gitkeep' 2>/dev/null | head -1)" ]; }

# ---- Terraform validate ----------------------------------------------------

if has_files "infra/envs/dev"; then
  if have terraform; then
    say "terraform validate infra/envs/dev"
    (
      cd infra/envs/dev
      terraform init -backend=false -input=false >/dev/null
      terraform validate
    ) || fail "terraform validate"
  else
    skip "terraform not installed"
  fi
else
  skip "infra/envs/dev (no terraform code yet)"
fi

# ---- Helm lint -------------------------------------------------------------

if have helm; then
  for chart in helm/*/; do
    if has_files "${chart}templates"; then
      say "helm lint $chart"
      helm lint "$chart" || fail "helm lint: $chart"
    else
      skip "$chart (no templates yet)"
    fi
  done
else
  skip "helm not installed"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  ok "validate passed"
  exit 0
else
  fail "validate FAILED"
  exit 1
fi
