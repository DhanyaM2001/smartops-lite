#!/usr/bin/env bash
# scripts/check-orphans.sh
#
# Fail (exit 1) if any billable AWS resource tagged project=smartops-lite is
# still running. Run this at the end of every session — right after
# `make eod` — to be sure nothing costs money overnight.
#
# WHITELIST: the S3 tf-state bucket, DynamoDB tf-lock table, and SSM
# parameters are considered "permanent shared infra" and are NOT orphans.
# They incur near-zero cost. Use `make nuke` to delete them at project
# retirement.
#
# Env:
#   AWS_PROFILE   (default: smartops)
#   AWS_REGION    (default: ap-south-1)

set -uo pipefail

AWS_PROFILE="${AWS_PROFILE:-smartops}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT="${PROJECT:-smartops-lite}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; RESET='\033[0m'
orphan=0
ok()   { printf "  ${GREEN}✔${RESET} %s\n" "$1"; }
bad()  { printf "  ${RED}✘${RESET} %s\n" "$1"; orphan=1; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }

aws_cli() { aws --profile "$AWS_PROFILE" --region "$AWS_REGION" "$@"; }

echo "▶ checking for orphaned resources tagged project=$PROJECT (region=$AWS_REGION)"

# ---- EC2 instances (billable while running or stopped-with-EBS) ---------
count=$(aws_cli ec2 describe-instances \
  --filters "Name=tag:project,Values=$PROJECT" \
            "Name=instance-state-name,Values=running,stopped,pending,stopping" \
  --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo 0)
[ "$count" -gt 0 ] && bad "$count EC2 instance(s)" || ok "no EC2 instances"

# ---- EBS volumes (orphans after instance termination) -------------------
count=$(aws_cli ec2 describe-volumes \
  --filters "Name=tag:project,Values=$PROJECT" \
  --query 'length(Volumes[?State!=`deleted`])' --output text 2>/dev/null || echo 0)
[ "$count" -gt 0 ] && bad "$count EBS volume(s)" || ok "no EBS volumes"

# ---- Elastic IPs (billable when unattached) -----------------------------
count=$(aws_cli ec2 describe-addresses \
  --filters "Name=tag:project,Values=$PROJECT" \
  --query 'length(Addresses)' --output text 2>/dev/null || echo 0)
[ "$count" -gt 0 ] && bad "$count Elastic IP(s)" || ok "no Elastic IPs"

# ---- NAT gateways (should NEVER exist) ----------------------------------
count=$(aws_cli ec2 describe-nat-gateways \
  --filter "Name=tag:project,Values=$PROJECT" \
  --query 'length(NatGateways[?State!=`deleted`])' --output text 2>/dev/null || echo 0)
[ "$count" -gt 0 ] && bad "$count NAT gateway(s) — SHOULD NEVER EXIST" || ok "no NAT gateways"

# ---- Load balancers -----------------------------------------------------
lbs=$(aws_cli elbv2 describe-load-balancers \
  --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true)
lb_count=0
for arn in $lbs; do
  proj=$(aws_cli elbv2 describe-tags --resource-arns "$arn" \
    --query "TagDescriptions[0].Tags[?Key=='project'].Value | [0]" --output text 2>/dev/null || echo "")
  [ "$proj" = "$PROJECT" ] && lb_count=$((lb_count+1))
done
[ "$lb_count" -gt 0 ] && bad "$lb_count load balancer(s)" || ok "no load balancers"

# ---- EKS clusters (should NEVER exist for THIS project) -----------------
# Filter by project tag to avoid false-positives on accounts hosting other
# projects. If an EKS cluster is untagged, we can't classify it — warn only.
eks_names=$(aws_cli eks list-clusters --query 'clusters[]' --output text 2>/dev/null || true)
eks_count=0
for name in $eks_names; do
  proj=$(aws_cli eks describe-cluster --name "$name" \
    --query "cluster.tags.project" --output text 2>/dev/null || echo "")
  [ "$proj" = "$PROJECT" ] && eks_count=$((eks_count+1))
done
[ "$eks_count" -gt 0 ] && bad "$eks_count EKS cluster(s) tagged $PROJECT — SHOULD NEVER EXIST" \
  || ok "no EKS clusters tagged $PROJECT"

# ---- RDS instances (should NEVER exist for THIS project) ----------------
rds_arns=$(aws_cli rds describe-db-instances \
  --query 'DBInstances[].DBInstanceArn' --output text 2>/dev/null || true)
rds_count=0
for arn in $rds_arns; do
  proj=$(aws_cli rds list-tags-for-resource --resource-name "$arn" \
    --query "TagList[?Key=='project'].Value | [0]" --output text 2>/dev/null || echo "")
  [ "$proj" = "$PROJECT" ] && rds_count=$((rds_count+1))
done
[ "$rds_count" -gt 0 ] && bad "$rds_count RDS instance(s) tagged $PROJECT" \
  || ok "no RDS instances tagged $PROJECT"

# ---- ECR repositories (workload images) — should be empty at EOD --------
repos=$(aws_cli ecr describe-repositories \
  --query "repositories[?starts_with(repositoryName, '${PROJECT}')].repositoryName" \
  --output text 2>/dev/null || true)
if [ -n "$repos" ]; then
  warn "ECR repos exist (permanent, near-zero cost): $repos"
else
  ok "no ECR repos"
fi

# ---- DynamoDB tables (excluding tf-lock which is whitelisted) -----------
tables=$(aws_cli dynamodb list-tables --query 'TableNames[]' --output text 2>/dev/null || true)
ddb_orphans=0
for t in $tables; do
  case "$t" in
    "${PROJECT}-tf-lock") continue ;;  # whitelisted: permanent infra
    smartops-*|"${PROJECT}"*)
      # check tag
      proj=$(aws_cli dynamodb list-tags-of-resource \
        --resource-arn "$(aws_cli dynamodb describe-table --table-name "$t" --query 'Table.TableArn' --output text 2>/dev/null)" \
        --query "Tags[?Key=='project'].Value | [0]" --output text 2>/dev/null || echo "")
      # If tagged project=smartops-lite AND not tf-lock, it's a workload table
      # (e.g. smartops-incidents) that should have been destroyed.
      if [ "$proj" = "$PROJECT" ]; then
        ddb_orphans=$((ddb_orphans+1))
      fi
      ;;
  esac
done
[ "$ddb_orphans" -gt 0 ] && bad "$ddb_orphans DynamoDB table(s) (excluding tf-lock)" || ok "no DynamoDB tables (tf-lock whitelisted)"

# ---- Lambda functions --------------------------------------------------
count=$(aws_cli lambda list-functions \
  --query "length(Functions[?starts_with(FunctionName, 'smartops-') || starts_with(FunctionName, '${PROJECT}')])" \
  --output text 2>/dev/null || echo 0)
[ "$count" -gt 0 ] && bad "$count Lambda function(s)" || ok "no Lambda functions"

# ---- EventBridge rules + custom bus ------------------------------------
count=$(aws_cli events list-event-buses \
  --query "length(EventBuses[?Name!='default' && starts_with(Name, 'smartops')])" \
  --output text 2>/dev/null || echo 0)
[ "$count" -gt 0 ] && bad "$count EventBridge bus(es)" || ok "no custom EventBridge buses"

# ---- SNS topics --------------------------------------------------------
count=$(aws_cli sns list-topics \
  --query "length(Topics[?contains(TopicArn, 'smartops')])" \
  --output text 2>/dev/null || echo 0)
[ "$count" -gt 0 ] && bad "$count SNS topic(s)" || ok "no SNS topics"

# ---- CloudWatch log groups (retention costs money at scale) ------------
count=$(aws_cli logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/smartops" \
  --query 'length(logGroups)' --output text 2>/dev/null || echo 0)
if [ "$count" -gt 0 ]; then
  warn "$count CloudWatch log group(s) — usually cheap, delete via 'make nuke' at retirement"
else
  ok "no CloudWatch log groups"
fi

# ---- VPCs (default VPC excluded) ---------------------------------------
count=$(aws_cli ec2 describe-vpcs \
  --filters "Name=tag:project,Values=$PROJECT" \
  --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)
[ "$count" -gt 0 ] && bad "$count VPC(s) with project tag" || ok "no project VPCs"

# ---- IAM roles/policies (near-zero cost but track for hygiene) ---------
count=$(aws_cli iam list-roles \
  --query "length(Roles[?starts_with(RoleName, 'smartops-')])" \
  --output text 2>/dev/null || echo 0)
if [ "$count" -gt 0 ]; then
  warn "$count IAM role(s) — free, deleted by 'make nuke' at retirement"
else
  ok "no IAM roles"
fi

echo ""
if [ "$orphan" -ne 0 ]; then
  printf "${RED}ORPHANS FOUND — run 'make eod' again or investigate before ending the session.${RESET}\n"
  exit 1
else
  printf "${GREEN}No orphaned billable resources.${RESET}\n"
fi
