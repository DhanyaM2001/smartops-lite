#!/usr/bin/env bash
# bootstrap-tf-backend.sh
#
# One-time (per AWS account/region) creation of the Terraform remote-state
# infrastructure:
#   - S3 bucket   : versioned + AES256-encrypted + all-public-access-blocked
#   - DynamoDB    : PAY_PER_REQUEST lock table (state locking)
#
# Idempotent. Safe to re-run: existing resources are detected and reported;
# the script only creates what's missing.
#
# Required env (or aws CLI defaults):
#   AWS_PROFILE  — CLI profile with permission to create S3/DynamoDB
#                  (default: "smartops" — matches docs/INSTALL.md section 3)
#   AWS_REGION   — where to create the resources (default: ap-south-1)
#   PROJECT      — project short name for bucket/table naming (default: smartops-lite)
#
# Usage:
#   bash scripts/bootstrap-tf-backend.sh
#
# What it prints at the end (also written to scripts/.backend-values,
# which `make tf-init` loads automatically):
#   BUCKET       : <name>
#   DDB_TABLE    : <name>
#   REGION       : <name>

set -euo pipefail

# ---- config ----------------------------------------------------------------

AWS_PROFILE="${AWS_PROFILE:-smartops}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT="${PROJECT:-smartops-lite}"

# ---- helpers ---------------------------------------------------------------

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
say()  { printf "${CYAN}==>${RESET} %s\n" "$*"; }
ok()   { printf "${GREEN}\xe2\x9c\x94${RESET} %s\n" "$*"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$*"; }
die()  { printf "${RED}\xe2\x9c\x98${RESET} %s\n" "$*" >&2; exit 1; }

aws_cli() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

# ---- 0. Sanity -------------------------------------------------------------

command -v aws >/dev/null 2>&1 || die "aws CLI not found in PATH. Run scripts/setup-wsl.sh first."

if ! aws_cli sts get-caller-identity >/dev/null 2>&1; then
  die "aws sts get-caller-identity failed for profile '$AWS_PROFILE' in region '$AWS_REGION'.
     Run 'aws configure --profile $AWS_PROFILE' first (see docs/INSTALL.md section 3)."
fi

ACCOUNT_ID=$(aws_cli sts get-caller-identity --query Account --output text)
BUCKET="${PROJECT}-tf-state-${ACCOUNT_ID}"
DDB_TABLE="${PROJECT}-tf-lock"

say "AWS account: $ACCOUNT_ID"
say "Region:      $AWS_REGION"
say "Bucket:      $BUCKET"
say "DDB table:   $DDB_TABLE"
echo ""

# ---- 1. S3 bucket ----------------------------------------------------------

if aws_cli s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  ok "S3 bucket '$BUCKET' already exists (skipping create)"
else
  say "Creating S3 bucket '$BUCKET'"
  # NOTE: us-east-1 does NOT accept LocationConstraint; every other region does
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws_cli s3api create-bucket --bucket "$BUCKET"
  else
    aws_cli s3api create-bucket \
      --bucket "$BUCKET" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
  ok "S3 bucket created"
fi

say "Enabling versioning"
aws_cli s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

say "Enabling server-side encryption (AES256)"
aws_cli s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

say "Blocking all public access"
aws_cli s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

say "Tagging bucket"
aws_cli s3api put-bucket-tagging \
  --bucket "$BUCKET" \
  --tagging "TagSet=[{Key=project,Value=$PROJECT},{Key=owner,Value=dhanym},{Key=env,Value=shared},{Key=purpose,Value=terraform-state}]"

ok "S3 bucket configured"

# ---- 2. DynamoDB lock table -----------------------------------------------

if aws_cli dynamodb describe-table --table-name "$DDB_TABLE" >/dev/null 2>&1; then
  ok "DynamoDB table '$DDB_TABLE' already exists (skipping create)"
else
  say "Creating DynamoDB lock table '$DDB_TABLE'"
  aws_cli dynamodb create-table \
    --table-name "$DDB_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --tags "Key=project,Value=$PROJECT" "Key=owner,Value=dhanym" "Key=env,Value=shared" "Key=purpose,Value=terraform-state-lock"
  say "Waiting for table to become ACTIVE"
  aws_cli dynamodb wait table-exists --table-name "$DDB_TABLE"
  ok "DynamoDB table created"
fi

# ---- 3. Summary ------------------------------------------------------------

echo ""
ok "Terraform backend is ready."
echo ""
echo "Backend values (make tf-init passes these to terraform init automatically):"
echo ""
echo "  BUCKET     = $BUCKET"
echo "  DDB_TABLE  = $DDB_TABLE"
echo "  REGION     = $AWS_REGION"
echo ""
echo "They are also stored in scripts/.backend-values (git-ignored) for automation."

# Write values to a git-ignored file for later scripts to source
cat > "$(dirname "$0")/.backend-values" <<EOF
# Auto-generated by bootstrap-tf-backend.sh. Do not commit.
export TF_BACKEND_BUCKET="$BUCKET"
export TF_BACKEND_DDB_TABLE="$DDB_TABLE"
export TF_BACKEND_REGION="$AWS_REGION"
EOF
chmod 600 "$(dirname "$0")/.backend-values"
ok "Wrote scripts/.backend-values (chmod 600, git-ignored)"
