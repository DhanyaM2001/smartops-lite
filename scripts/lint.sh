#!/usr/bin/env bash
# lint.sh — static linting for every language in the repo.
#
# Grows per module. If a linter is missing OR its target directory has no
# real code yet, the check is skipped with a friendly message (never a hard
# failure), so `make lint` stays green on a freshly-cloned tree.
set -uo pipefail

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}\xe2\x9c\x94${RESET} %s\n" "$*"; }
skip() { printf "${YELLOW}\xe2\x8b\xaf${RESET} skip: %s\n" "$*"; }
fail() { printf "${RED}\xe2\x9c\x98${RESET} %s\n" "$*"; FAILED=1; }

FAILED=0
have() { command -v "$1" >/dev/null 2>&1; }
has_real_files() {
  # true if the dir exists and contains at least one non-.gitkeep file
  local dir="$1"
  [ -d "$dir" ] && [ -n "$(find "$dir" -type f ! -name '.gitkeep' 2>/dev/null | head -1)" ]
}

# ---- Python (ruff + mypy) --------------------------------------------------

for py_dir in apps/crashy-app controller lambdas/rca-generator lambdas/remediator lambdas/mttr-aggregator; do
  if ! has_real_files "$py_dir"; then
    skip "python $py_dir (no code yet)"
    continue
  fi
  if have ruff; then
    say "ruff check $py_dir"
    ruff check "$py_dir" || fail "ruff: $py_dir"
  else
    skip "ruff not installed"
  fi
  if have mypy; then
    say "mypy $py_dir"
    mypy "$py_dir" || fail "mypy: $py_dir"
  else
    skip "mypy not installed"
  fi
done

# ---- Dockerfiles (hadolint) -----------------------------------------------

for dockerfile in $(find . -name Dockerfile -not -path './.git/*' 2>/dev/null); do
  if have hadolint; then
    say "hadolint $dockerfile"
    hadolint "$dockerfile" || fail "hadolint: $dockerfile"
  else
    skip "hadolint not installed"
    break
  fi
done

# ---- Terraform (fmt + tflint) ---------------------------------------------

if has_real_files "infra"; then
  if have terraform; then
    say "terraform fmt -check -recursive infra/"
    terraform -chdir=infra fmt -check -recursive || fail "terraform fmt: infra/"
  else
    skip "terraform not installed"
  fi
  if have tflint; then
    # AWS ruleset plugin (see .tflint.hcl) needs to be fetched once per
    # workspace. `tflint --init` is idempotent and cheap; skipping it is
    # what caused CI to fail with "plugin `aws` not found".
    say "tflint --init (fetch plugins)"
    ( cd infra/envs/dev && tflint --init >/dev/null ) || fail "tflint --init: infra/envs/dev"
    say "tflint infra/envs/dev"
    ( cd infra/envs/dev && tflint ) || fail "tflint: infra/envs/dev"
  else
    skip "tflint not installed"
  fi
else
  skip "infra/ (no terraform code yet)"
fi

# ---- YAML (yamllint) ------------------------------------------------------

if have yamllint; then
  # Use the repo-root config which explicitly ignores Helm templates
  # (they contain {{ .Values.x }} which isn't valid YAML).
  YL_ARGS="-c .yamllint.yaml"
  [ -f .yamllint.yaml ] || YL_ARGS=""
  say "yamllint helm/ .github/ (config: ${YL_ARGS:-default})"
  # shellcheck disable=SC2086
  yamllint $YL_ARGS helm/ .github/ || fail "yamllint"
else
  skip "yamllint not installed"
fi

# ---- Shell (shellcheck) ---------------------------------------------------

if have shellcheck; then
  say "shellcheck scripts/*.sh"
  shellcheck scripts/*.sh || fail "shellcheck"
else
  skip "shellcheck not installed"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
  ok "lint passed"
  exit 0
else
  fail "lint FAILED"
  exit 1
fi
