#!/usr/bin/env bash
# scripts/teardown.sh — nuclear teardown when 'terraform destroy' can't finish.
#
# WARNING: force-terminates every EC2 instance / EBS volume tagged
#          project=smartops-lite. Use only when normal 'make eod' has failed.
#
# For the safe daily teardown, use `make eod` instead (calls scripts/eod.sh).
# For full project retirement (including state bucket, IAM), use `make nuke`.

set -uo pipefail

AWS_PROFILE="${AWS_PROFILE:-smartops}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT="${PROJECT:-smartops-lite}"

aws_cli() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

read -rp "This will FORCE-DESTROY EC2/EBS tagged project=$PROJECT in $AWS_REGION (profile: $AWS_PROFILE). Type YES to continue: " confirm
[ "$confirm" = "YES" ] || { echo "aborted."; exit 0; }

echo "→ terminating EC2 instances..."
ids=$(aws_cli ec2 describe-instances \
  --filters "Name=tag:project,Values=$PROJECT" "Name=instance-state-name,Values=running,stopped,pending,stopping" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo "")
if [ -n "$ids" ]; then
  # shellcheck disable=SC2086
  aws_cli ec2 terminate-instances --instance-ids $ids >/dev/null || true
  echo "→ waiting for termination..."
  # shellcheck disable=SC2086
  aws_cli ec2 wait instance-terminated --instance-ids $ids || true
else
  echo "  (no instances)"
fi

echo "→ deleting available EBS volumes..."
vols=$(aws_cli ec2 describe-volumes \
  --filters "Name=tag:project,Values=$PROJECT" "Name=status,Values=available" \
  --query 'Volumes[].VolumeId' --output text 2>/dev/null || echo "")
for v in $vols; do
  aws_cli ec2 delete-volume --volume-id "$v" || true
done

echo "→ running terraform destroy for anything left..."
if [ -d infra/envs/dev/.terraform ]; then
  ( cd infra/envs/dev && terraform destroy -auto-approve ) || true
else
  echo "  (no terraform state — skipping)"
fi

echo "→ running orphan check..."
AWS_PROFILE="$AWS_PROFILE" AWS_REGION="$AWS_REGION" \
  bash "$(dirname "$0")/check-orphans.sh"
