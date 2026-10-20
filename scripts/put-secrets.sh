#!/usr/bin/env bash
# put-secrets.sh
#
# Stores project secrets (Slack incoming webhook + Groq API key) in AWS SSM
# Parameter Store as SecureString. Lambdas and the K3s controller read them
# at runtime via boto3 + IAM permission — never from env, never from git.
#
# Reads values from environment variables to avoid ever writing secrets to
# disk. Recommended way to call this script:
#
#   read -rs SLACK_WEBHOOK_URL   ; export SLACK_WEBHOOK_URL
#   read -rs GROQ_API_KEY        ; export GROQ_API_KEY
#   bash scripts/put-secrets.sh
#
# (read -rs is silent — no echo — so the value isn't visible in your history
# or the terminal scrollback.)
#
# Required env (per secret):
#   SLACK_WEBHOOK_URL       — https://hooks.slack.com/services/T.../B.../...   (needed unless --only-groq / --only-signing)
#   GROQ_API_KEY            — gsk_...                                          (needed unless --only-slack / --only-signing)
#   SLACK_SIGNING_SECRET    — 32-hex-char string from Slack app Basic Info     (Module 7 — needed unless --only-slack / --only-groq)
# Optional env:
#   AWS_PROFILE         — default: smartops
#   AWS_REGION          — default: ap-south-1
#   PROJECT_ENV         — default: dev  (parameter path prefix)
#
# Idempotent: if a parameter already exists, it is overwritten (--overwrite).
#
# Usage:
#   bash scripts/put-secrets.sh                    # writes all three
#   bash scripts/put-secrets.sh --only-slack       # writes only Slack webhook
#   bash scripts/put-secrets.sh --only-groq        # writes only Groq key
#   bash scripts/put-secrets.sh --only-signing     # writes only Slack signing secret (Module 7)
#   bash scripts/put-secrets.sh --verify           # only prints what's stored

set -euo pipefail

# ---- config ----------------------------------------------------------------

AWS_PROFILE="${AWS_PROFILE:-smartops}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT_ENV="${PROJECT_ENV:-dev}"

PARAM_SLACK="/smartops/${PROJECT_ENV}/slack_webhook"
PARAM_GROQ="/smartops/${PROJECT_ENV}/groq_api_key"
PARAM_SIGNING="/smartops/${PROJECT_ENV}/slack_signing_secret"

# ---- helpers ---------------------------------------------------------------

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}\xe2\x9c\x94${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$*"; }
die()  { printf "${RED}\xe2\x9c\x98${RESET} %s\n" "$*" >&2; exit 1; }

aws_cli() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

put_secret() {
  # AWS quirk: `ssm put-parameter --overwrite` CANNOT be combined with --tags.
  # So we branch: create-with-tags on first run, overwrite-then-retag on updates.
  local name="$1" value="$2" desc="$3"
  if [ -z "$value" ]; then
    warn "Empty value for $name — skipping"
    return 0
  fi

  if aws_cli ssm get-parameter --name "$name" >/dev/null 2>&1; then
    say "Updating existing $name"
    aws_cli ssm put-parameter \
      --name "$name" \
      --value "$value" \
      --type SecureString \
      --description "$desc" \
      --overwrite >/dev/null
    # Re-apply tags separately (idempotent).
    aws_cli ssm add-tags-to-resource \
      --resource-type Parameter \
      --resource-id "$name" \
      --tags "Key=project,Value=smartops-lite" "Key=env,Value=$PROJECT_ENV" >/dev/null 2>&1 || true
    ok "Updated $name"
  else
    say "Creating $name"
    aws_cli ssm put-parameter \
      --name "$name" \
      --value "$value" \
      --type SecureString \
      --description "$desc" \
      --tags "Key=project,Value=smartops-lite" "Key=env,Value=$PROJECT_ENV" >/dev/null
    ok "Created $name"
  fi
}

# ---- arg parsing -----------------------------------------------------------

ONLY_SLACK=0
ONLY_GROQ=0
ONLY_SIGNING=0
VERIFY_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --only-slack)   ONLY_SLACK=1 ;;
    --only-groq)    ONLY_GROQ=1  ;;
    --only-signing) ONLY_SIGNING=1 ;;
    --verify)       VERIFY_ONLY=1 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "unknown arg: $1 (see --help)" ;;
  esac
  shift
done

# Any --only-* switch means "skip everything else". Compute that once.
ANY_ONLY=$(( ONLY_SLACK + ONLY_GROQ + ONLY_SIGNING ))

# ---- 0. Sanity -------------------------------------------------------------

command -v aws >/dev/null 2>&1 || die "aws CLI not found. Run scripts/setup-wsl.sh first."

aws_cli sts get-caller-identity >/dev/null 2>&1 \
  || die "aws sts get-caller-identity failed for profile '$AWS_PROFILE'."

# ---- 1. Verify-only path ---------------------------------------------------

if [ "$VERIFY_ONLY" -eq 1 ]; then
  say "Existing SSM parameters under /smartops/${PROJECT_ENV}/"
  aws_cli ssm get-parameters \
    --names "$PARAM_SLACK" "$PARAM_GROQ" "$PARAM_SIGNING" \
    --query 'Parameters[].[Name,Type,LastModifiedDate]' \
    --output table
  exit 0
fi

# ---- 2. Write secrets ------------------------------------------------------
# Rule: if any --only-* flag is set, ONLY that param is written; otherwise all
# three are written (skipping any whose env var is empty).

should_write_slack()   { [ "$ANY_ONLY" -eq 0 ] || [ "$ONLY_SLACK"   -eq 1 ]; }
should_write_groq()    { [ "$ANY_ONLY" -eq 0 ] || [ "$ONLY_GROQ"    -eq 1 ]; }
should_write_signing() { [ "$ANY_ONLY" -eq 0 ] || [ "$ONLY_SIGNING" -eq 1 ]; }

if should_write_slack; then
  if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    put_secret "$PARAM_SLACK" "$SLACK_WEBHOOK_URL" "Slack incoming webhook for #smartops-alerts"
  elif [ "$ONLY_SLACK" -eq 1 ]; then
    die "SLACK_WEBHOOK_URL not set. Export it first (see script header for the safe pattern)."
  else
    warn "skip $PARAM_SLACK — SLACK_WEBHOOK_URL empty; export and re-run to store."
  fi
fi

if should_write_groq; then
  if [ -n "${GROQ_API_KEY:-}" ]; then
    put_secret "$PARAM_GROQ"  "$GROQ_API_KEY"      "Groq API key (Llama 3 70B) for RCA Lambda"
  elif [ "$ONLY_GROQ" -eq 1 ]; then
    die "GROQ_API_KEY not set. Export it first (see script header for the safe pattern)."
  else
    warn "skip $PARAM_GROQ — GROQ_API_KEY empty; export and re-run to store."
  fi
fi

if should_write_signing; then
  if [ -n "${SLACK_SIGNING_SECRET:-}" ]; then
    put_secret "$PARAM_SIGNING" "$SLACK_SIGNING_SECRET" "Slack app signing secret (Module 7 — verifies interaction payloads)"
  elif [ "$ONLY_SIGNING" -eq 1 ]; then
    die "SLACK_SIGNING_SECRET not set. Export it first (see script header for the safe pattern)."
  else
    # Module 0 flow only needs webhook + Groq; signing secret is a Module 7
    # prerequisite. Skip quietly (with a hint) instead of aborting Module 0.
    warn "skip $PARAM_SIGNING — SLACK_SIGNING_SECRET empty (needed only at Module 7; run 'make put-signing-secret' then)."
  fi
fi

echo ""
ok "Secrets stored."
say "Verifying (names only, values not decrypted):"
aws_cli ssm get-parameters \
  --names "$PARAM_SLACK" "$PARAM_GROQ" "$PARAM_SIGNING" \
  --query 'Parameters[].[Name,Type,LastModifiedDate]' \
  --output table
