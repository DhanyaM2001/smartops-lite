#!/usr/bin/env bash
# test.sh — run unit tests for every Python package with tests present.
#
# Grows per module. Skips packages with no tests yet so `make test` stays
# green on a fresh clone.
set -uo pipefail

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}\xe2\x9c\x94${RESET} %s\n" "$*"; }
skip() { printf "${YELLOW}\xe2\x8b\xaf${RESET} skip: %s\n" "$*"; }
fail() { printf "${RED}\xe2\x9c\x98${RESET} %s\n" "$*"; FAILED=1; }

FAILED=0
have() { command -v "$1" >/dev/null 2>&1; }

if ! have poetry; then
  skip "poetry not installed — cannot run tests"
  exit 0
fi

has_tests() {
  local dir="$1"
  [ -d "$dir/tests" ] && [ -n "$(find "$dir/tests" -name 'test_*.py' 2>/dev/null | head -1)" ]
}

for pkg in apps/crashy-app controller lambdas/rca-generator lambdas/remediator lambdas/mttr-aggregator; do
  if [ ! -f "$pkg/pyproject.toml" ]; then
    skip "$pkg (no pyproject.toml yet)"
    continue
  fi
  if ! has_tests "$pkg"; then
    skip "$pkg (no tests yet)"
    continue
  fi
  say "pytest $pkg"
  ( cd "$pkg" && poetry run pytest -q ) || fail "pytest: $pkg"
done

echo ""
if [ "$FAILED" -eq 0 ]; then
  ok "test passed"
  exit 0
else
  fail "test FAILED"
  exit 1
fi
