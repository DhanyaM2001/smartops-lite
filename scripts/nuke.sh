#!/usr/bin/env bash
# scripts/nuke.sh — full project retirement.
#
# Deletes EVERYTHING, including the permanent shared infra:
#   - Everything eod.sh deletes (workloads + terraform-managed AWS)
#   - S3 tf-state bucket (all versions + delete markers first)
#   - DynamoDB tf-lock table
#   - All SSM parameters under /smartops/*
#   - IAM CLI user 'smartops-cli' and its access keys/policies
#   - CloudWatch log groups under /aws/lambda/smartops*
#   - Local files: kubeconfig, scripts/.backend-values
#
# Use ONLY when you are done with the project forever (or restarting from
# zero for testing). Run `make eod` for the daily-safe teardown instead.
#
# Requires typing 'NUKE' to confirm. Cannot be undone.

set -uo pipefail

AWS_PROFILE="${AWS_PROFILE:-smartops}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT="${PROJECT:-smartops-lite}"
PROJECT_ENV="${PROJECT_ENV:-dev}"

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "  ${GREEN}✔${RESET} %s\n" "$*"; }
skip() { printf "  ${YELLOW}—${RESET} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
die()  { printf "  ${RED}✘${RESET} %s\n" "$*" >&2; exit 1; }

aws_cli() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

cat <<'BANNER'
────────────────────────────────────────────────────────────
   NUKE — full project retirement
────────────────────────────────────────────────────────────
BANNER
say "Profile:   $AWS_PROFILE"
say "Region:    $AWS_REGION"
say "Project:   $PROJECT"

if ! aws_cli sts get-caller-identity >/dev/null 2>&1; then
  die "AWS profile '$AWS_PROFILE' can't authenticate. Aborting."
fi
ACCOUNT_ID=$(aws_cli sts get-caller-identity --query Account --output text)
BUCKET="${PROJECT}-tf-state-${ACCOUNT_ID}"
DDB_TABLE="${PROJECT}-tf-lock"

cat <<EOF

This will PERMANENTLY DELETE, in account $ACCOUNT_ID:

  1. Every AWS resource tagged project=$PROJECT (via 'make eod')
  2. S3 bucket           : $BUCKET  (including ALL versions)
  3. DynamoDB table      : $DDB_TABLE
  4. SSM parameters      : /smartops/*
  5. CloudWatch logs     : /aws/lambda/smartops*
  6. IAM user            : smartops-cli (+ access keys + policies)
  7. Local files         : ~/.kube/config-smartops, scripts/.backend-values

You cannot undo this.

EOF

read -rp "Type NUKE (uppercase) to confirm: " ans
[ "$ans" = "NUKE" ] || { echo "aborted."; exit 0; }

# ---- 1. Standard EOD teardown first -------------------------------------
say "1/7  Running standard EOD teardown"
AWS_PROFILE="$AWS_PROFILE" AWS_REGION="$AWS_REGION" PROJECT="$PROJECT" \
  bash "$(dirname "$0")/eod.sh" --yes || warn "eod.sh exited with errors — continuing anyway"

# ---- 2. Empty and delete S3 tf-state bucket -----------------------------
say "2/7  Emptying + deleting S3 bucket $BUCKET"
if aws_cli s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  # Delete all object versions
  aws_cli s3api list-object-versions --bucket "$BUCKET" \
    --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null | \
    jq -c '.[]?' 2>/dev/null | while read -r item; do
      key=$(echo "$item" | jq -r .Key)
      ver=$(echo "$item" | jq -r .VersionId)
      aws_cli s3api delete-object --bucket "$BUCKET" --key "$key" --version-id "$ver" >/dev/null || true
    done
  # Delete all delete markers
  aws_cli s3api list-object-versions --bucket "$BUCKET" \
    --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json 2>/dev/null | \
    jq -c '.[]?' 2>/dev/null | while read -r item; do
      key=$(echo "$item" | jq -r .Key)
      ver=$(echo "$item" | jq -r .VersionId)
      aws_cli s3api delete-object --bucket "$BUCKET" --key "$key" --version-id "$ver" >/dev/null || true
    done
  aws_cli s3api delete-bucket --bucket "$BUCKET" && ok "deleted $BUCKET"
else
  skip "$BUCKET doesn't exist"
fi

# ---- 3. Delete DynamoDB lock table --------------------------------------
say "3/7  Deleting DynamoDB $DDB_TABLE"
if aws_cli dynamodb describe-table --table-name "$DDB_TABLE" >/dev/null 2>&1; then
  aws_cli dynamodb delete-table --table-name "$DDB_TABLE" >/dev/null && ok "deleted $DDB_TABLE"
else
  skip "$DDB_TABLE doesn't exist"
fi

# ---- 4. Delete SSM parameters -------------------------------------------
say "4/7  Deleting SSM parameters under /smartops/"
params=$(aws_cli ssm describe-parameters \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=/smartops/" \
  --query 'Parameters[].Name' --output text 2>/dev/null || echo "")
if [ -n "$params" ]; then
  # SSM delete-parameters accepts up to 10 at a time
  # shellcheck disable=SC2086
  set -- $params
  while [ $# -gt 0 ]; do
    batch=("$@"); batch=("${batch[@]:0:10}")
    aws_cli ssm delete-parameters --names "${batch[@]}" >/dev/null || true
    shift $(( ${#batch[@]} < $# ? ${#batch[@]} : $# ))
  done
  ok "deleted SSM params"
else
  skip "no SSM params under /smartops/"
fi

# ---- 5. CloudWatch log groups -------------------------------------------
say "5/7  Deleting CloudWatch log groups /aws/lambda/smartops*"
groups=$(aws_cli logs describe-log-groups --log-group-name-prefix "/aws/lambda/smartops" \
  --query 'logGroups[].logGroupName' --output text 2>/dev/null || echo "")
for g in $groups; do
  aws_cli logs delete-log-group --log-group-name "$g" && ok "deleted $g" || warn "failed $g"
done
[ -z "$groups" ] && skip "none found"

# ---- 6. IAM user smartops-cli -------------------------------------------
say "6/7  Deleting IAM user smartops-cli"
if aws_cli iam get-user --user-name smartops-cli >/dev/null 2>&1; then
  # Detach managed policies
  aws_cli iam list-attached-user-policies --user-name smartops-cli \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | tr '\t' '\n' | while read -r arn; do
      [ -n "$arn" ] && aws_cli iam detach-user-policy --user-name smartops-cli --policy-arn "$arn"
    done
  # Delete inline policies
  aws_cli iam list-user-policies --user-name smartops-cli \
    --query 'PolicyNames[]' --output text 2>/dev/null | tr '\t' '\n' | while read -r name; do
      [ -n "$name" ] && aws_cli iam delete-user-policy --user-name smartops-cli --policy-name "$name"
    done
  # Delete access keys
  aws_cli iam list-access-keys --user-name smartops-cli \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null | tr '\t' '\n' | while read -r key; do
      [ -n "$key" ] && aws_cli iam delete-access-key --user-name smartops-cli --access-key-id "$key"
    done
  aws_cli iam delete-user --user-name smartops-cli && ok "deleted iam/smartops-cli"
else
  skip "iam/smartops-cli doesn't exist"
fi

# ---- 7. Local files -----------------------------------------------------
say "7/7  Local files"
rm -f "$HOME/.kube/config-smartops"          && ok "removed $HOME/.kube/config-smartops"
rm -f scripts/.backend-values                 && ok "removed scripts/.backend-values"
[ -d infra/envs/dev/.terraform ] && rm -rf infra/envs/dev/.terraform && ok "removed local .terraform dir"

echo ""
printf "${GREEN}Nuke complete.${RESET} Project is fully retired.\n"
echo "  Your AWS account and IAM console user (root/dhanym) still exist —"
echo "  only the CLI user + project resources were deleted."
