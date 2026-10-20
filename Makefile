# SmartOps-Lite — top-level Makefile (the single entry point)
#
# EVERYTHING is triggered from here. Read this file top-to-bottom to get the
# full picture of what a "starting point" looks like — there is no hidden
# main() elsewhere.
#
# The most-used verbs:
#   make help          # list every target with a one-liner
#   make status        # what's currently running (read-only)
#   make module-0      # full Module 0 (local setup + backend + secrets + repo)
#   make up            # provision AWS + deploy everything (Module 1+)
#   make eod           # END-OF-DAY: safe teardown of everything billable
#   make nuke          # PERMANENT retirement (delete everything, incl. state)
#
# Naming rule:
#   - lowercase-hyphen for verbs (`make bootstrap-backend`)
#   - short first, exposition in `## comment` (rendered by `make help`)
#
# All scripts assume: WSL Ubuntu, aws-cli + kubectl + helm installed.
# See docs/INSTALL.md (install & deploy) and docs/REFERENCE.md (encyclopedia).

SHELL         := /bin/bash
.ONESHELL:
.DEFAULT_GOAL := help
.SHELLFLAGS   := -eu -o pipefail -c

REGION        ?= ap-south-1
ENV           ?= dev
PROJECT       ?= smartops-lite
AWS_PROFILE   ?= smartops
TF_DIR        := infra/envs/$(ENV)
NAMESPACE     := demo
export AWS_PROFILE
export AWS_REGION := $(REGION)
export PROJECT
export PROJECT_ENV := $(ENV)

# ANSI colours
CYAN  := \033[36m
GREEN := \033[32m
YELLOW:= \033[33m
RED   := \033[31m
RESET := \033[0m

# ---- help ---------------------------------------------------------------
.PHONY: help
help: ## show this help
	@awk 'BEGIN {FS = ":.*?## "} \
	  /^# ==== / { sub(/^# ==== /,""); sub(/ ====$$/,""); printf "\n$(CYAN)%s$(RESET)\n", $$0; next } \
	  /^[a-zA-Z0-9_.-]+:.*?## / { printf "  $(GREEN)%-22s$(RESET) %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)

# ==== Module 0 — local setup + shared AWS infra ====
.PHONY: setup bootstrap-backend put-secrets verify-secrets init-repo module-0

setup: ## Module 0.1 — install WSL toolchain (Ubuntu/WSL only, idempotent)
	@bash scripts/setup-wsl.sh

bootstrap-backend: ## Module 0.2 — create S3 state bucket + DynamoDB lock table
	@bash scripts/bootstrap-tf-backend.sh

put-secrets: ## Module 0.3 — write Slack + Groq secrets to SSM (env-driven)
	@bash scripts/put-secrets.sh

verify-secrets: ## Module 0.3 — show SSM param metadata (values NOT decrypted)
	@bash scripts/put-secrets.sh --verify

init-repo: ## Module 0.4 — git init + gh repo create --public + push
	@bash scripts/init-repo.sh

module-0: ## Module 0 — end-to-end (skips put-secrets — do that manually with env)
	@echo -e "$(CYAN)==> Running Module 0 pipeline$(RESET)"
	@$(MAKE) --no-print-directory setup
	@$(MAKE) --no-print-directory bootstrap-backend
	@echo -e "$(YELLOW)!  put-secrets needs env vars — run manually:$(RESET)"
	@echo "     read -rs SLACK_WEBHOOK_URL; export SLACK_WEBHOOK_URL"
	@echo "     read -rs GROQ_API_KEY;      export GROQ_API_KEY"
	@echo "     make put-secrets"
	@echo -e "$(CYAN)==> Then finish with:$(RESET) make init-repo"

# ==== Daily lifecycle ====
.PHONY: up down eod status

up: tf-apply kube-config helm-install verify ## bring the stack UP (~15 min once Module 1+ exists)
	@echo -e "$(GREEN)✔ stack up$(RESET)"

down: ## soft teardown — alias for 'make eod'
	@$(MAKE) --no-print-directory eod

eod: ## END-OF-DAY: safely destroy billable resources (keeps state + secrets)
	@bash scripts/eod.sh

status: ## one-glance: what's running + current-month cost (read-only)
	@bash scripts/status.sh

# ==== Terraform (individual verbs) ====
.PHONY: tf-init tf-plan tf-apply tf-destroy

tf-init: ## terraform init (auto-loads scripts/.backend-values from Module 0)
	@[ -d $(TF_DIR) ] || { echo "$(TF_DIR) doesn't exist yet — write Module 1 first"; exit 1; }
	@[ -f scripts/.backend-values ] || { echo "scripts/.backend-values missing — run 'make bootstrap-backend' first"; exit 1; }
	@# shellcheck source=/dev/null
	@source scripts/.backend-values && \
	  cd $(TF_DIR) && terraform init -reconfigure \
	    -backend-config="bucket=$$TF_BACKEND_BUCKET" \
	    -backend-config="key=envs/$(ENV)/terraform.tfstate" \
	    -backend-config="region=$$TF_BACKEND_REGION" \
	    -backend-config="dynamodb_table=$$TF_BACKEND_DDB_TABLE" \
	    -backend-config="encrypt=true"

tf-plan: ## terraform plan
	@[ -d $(TF_DIR) ] || { echo "$(TF_DIR) doesn't exist yet"; exit 1; }
	@cd $(TF_DIR) && terraform plan

tf-apply: ## terraform apply (auto-approve)
	@[ -d $(TF_DIR) ] || { echo "$(TF_DIR) doesn't exist yet"; exit 1; }
	@cd $(TF_DIR) && terraform apply -auto-approve

tf-destroy: ## terraform destroy (auto-approve, best-effort)
	@if [ -d $(TF_DIR)/.terraform ]; then \
	  cd $(TF_DIR) && terraform destroy -auto-approve || true; \
	else \
	  echo "$(TF_DIR) not initialised — nothing to destroy"; \
	fi

# ==== Kubernetes ====
.PHONY: kube-config kube-api-tunnel helm-install helm-uninstall deploy-crashy-app

kube-config: ## fetch kubeconfig into ~/.kube/config-smartops, pointed at the SSM tunnel (127.0.0.1:6443)
	@[ -d $(TF_DIR)/.terraform ] || { echo "TF not initialised — run 'make tf-apply' first"; exit 1; }
	@# The API has no public ingress, so the uploaded public-IP server URL is
	@# unreachable; kubectl only gets in through `make kube-api-tunnel`.
	@# Fetch into a variable first: with .ONESHELL, a failure mid-`&&`-chain
	@# doesn't trip `-e`, and a direct redirect would truncate a good config.
	@cd $(TF_DIR)
	@# The SSM kubeconfig survives across servers; wait until the current
	@# server has stamped its ID (written after the kubeconfig) before reading.
	@EXPECTED=$$(terraform output -raw k3s_server_instance_id)
	@CURRENT=""
	@for i in $$(seq 1 30); do \
	  CURRENT=$$(aws ssm get-parameter --name /smartops/$(ENV)/k3s_server_instance_id \
	             --query Parameter.Value --output text 2>/dev/null || true); \
	  [ "$$CURRENT" = "$$EXPECTED" ] && break; \
	  echo "  waiting for server $$EXPECTED to finish bootstrapping ($$i/30)..."; \
	  sleep 10; \
	done
	@[ "$$CURRENT" = "$$EXPECTED" ] || { echo "$(RED)✘ server $$EXPECTED never published its kubeconfig — check its console log$(RESET)"; exit 1; }
	@KC=$$(eval "$$(terraform output -raw kubeconfig_fetch_cmd)")
	@printf '%s\n' "$$KC" | sed 's|https://.*:6443|https://127.0.0.1:6443|' > $$HOME/.kube/config-smartops
	@chmod 600 $$HOME/.kube/config-smartops
	@echo "export KUBECONFIG=$$HOME/.kube/config-smartops"

kube-api-tunnel: ## open SSM port-forward to K3s API on localhost:6443 (foreground; Ctrl-C to stop)
	@[ -d $(TF_DIR)/.terraform ] || { echo "TF not initialised — run 'make tf-apply' first"; exit 1; }
	@echo "$(CYAN)==>$(RESET) opening SSM tunnel to K3s API — keep this terminal open"
	@echo "     (in a second terminal: 'export KUBECONFIG=$$HOME/.kube/config-smartops' && kubectl get nodes)"
	@cd $(TF_DIR) && eval "$$(terraform output -raw kube_api_tunnel_cmd)"

helm-install: ## install controller + demo app (skips charts that don't exist yet)
	@if [ -d helm/smartops-controller ]; then \
	  $(MAKE) --no-print-directory helm-install-controller; \
	else echo "  skip: helm/smartops-controller (chart not yet written)"; fi
	@if [ -d helm/crashy-app ]; then \
	  $(MAKE) --no-print-directory helm-install-crashy; \
	else echo "  skip: helm/crashy-app (chart not yet written)"; fi

helm-uninstall: ## uninstall all helm releases (best-effort)
	-@KUBECONFIG=$$HOME/.kube/config-smartops helm uninstall app -n $(NAMESPACE)
	-@KUBECONFIG=$$HOME/.kube/config-smartops helm uninstall ctrl -n smartops

helm-install-crashy: ## install/upgrade crashy-app; pulls ECR URL from terraform outputs
	@[ -d $(TF_DIR)/.terraform ] || { echo "TF not initialised — run 'make tf-apply' first"; exit 1; }
	@REPO=$$(cd $(TF_DIR) && terraform output -json ecr_repository_urls 2>/dev/null | jq -r '."smartops/crashy-app" // empty'); \
	  if [ -z "$$REPO" ]; then \
	    echo "$(RED)✘ ecr_repository_urls output missing — is Module 3 applied?$(RESET)"; exit 1; \
	  fi; \
	  echo "$(CYAN)==>$(RESET) helm upgrade --install app helm/crashy-app  (image.repository=$$REPO)"; \
	  KUBECONFIG=$$HOME/.kube/config-smartops helm upgrade --install app helm/crashy-app \
	    -n $(NAMESPACE) --create-namespace \
	    --set image.repository="$$REPO" \
	    --set image.tag="$${IMAGE_TAG:-latest}"

helm-install-controller: ## install/upgrade smartops-controller; pulls ECR URL + bus name from tf outputs
	@[ -d $(TF_DIR)/.terraform ] || { echo "TF not initialised — run 'make tf-apply' first"; exit 1; }
	@REPO=$$(cd $(TF_DIR) && terraform output -json ecr_repository_urls 2>/dev/null | jq -r '."smartops/controller" // empty'); \
	  BUS=$$(cd $(TF_DIR) && terraform output -raw event_bus_name 2>/dev/null || true); \
	  if [ -z "$$REPO" ]; then \
	    echo "$(RED)✘ ecr_repository_urls['smartops/controller'] missing — is Module 4 applied?$(RESET)"; exit 1; \
	  fi; \
	  if [ -z "$$BUS" ]; then \
	    echo "$(RED)✘ event_bus_name output missing — is Module 4 applied?$(RESET)"; exit 1; \
	  fi; \
	  echo "$(CYAN)==>$(RESET) helm upgrade --install ctrl helm/smartops-controller  (image=$$REPO, bus=$$BUS)"; \
	  KUBECONFIG=$$HOME/.kube/config-smartops helm upgrade --install ctrl helm/smartops-controller \
	    -n smartops --create-namespace \
	    --set image.repository="$$REPO" \
	    --set image.tag="$${IMAGE_TAG:-latest}" \
	    --set env.AWS_REGION="$(REGION)" \
	    --set env.EVENT_BUS_NAME="$$BUS"

deploy-crashy-app: helm-install-crashy ## alias for helm-install-crashy

# ==== Module 3+4 — image build + ECR push ====
.PHONY: ecr-login docker-build-crashy docker-push-crashy docker-build-controller docker-push-controller

CRASHY_DIR      := apps/crashy-app
CONTROLLER_DIR  := controller
IMAGE_TAG       ?= latest
GIT_SHA         := $(shell git rev-parse --short HEAD 2>/dev/null || echo "nogit")

ecr-login: ## docker-login to this account's ECR registry (uses AWS_PROFILE)
	@REGISTRY=$$(cd $(TF_DIR) && terraform output -raw ecr_registry_url 2>/dev/null || true); \
	  if [ -z "$$REGISTRY" ]; then \
	    ACCOUNT=$$(aws sts get-caller-identity --query Account --output text); \
	    REGISTRY="$$ACCOUNT.dkr.ecr.$(REGION).amazonaws.com"; \
	  fi; \
	  echo "$(CYAN)==>$(RESET) logging in to $$REGISTRY"; \
	  aws ecr get-login-password --region $(REGION) \
	    | docker login --username AWS --password-stdin "$$REGISTRY"

docker-build-crashy: ## build the crashy-app image locally (tag: :latest and :git-<sha>)
	@[ -d $(CRASHY_DIR) ] || { echo "$(CRASHY_DIR) not found"; exit 1; }
	@echo "$(CYAN)==>$(RESET) docker build $(CRASHY_DIR) → crashy-app:$(IMAGE_TAG), crashy-app:git-$(GIT_SHA)"
	@docker build \
	  -t crashy-app:$(IMAGE_TAG) \
	  -t crashy-app:git-$(GIT_SHA) \
	  $(CRASHY_DIR)

docker-push-crashy: ecr-login docker-build-crashy ## build + tag + push crashy-app to ECR
	@REPO=$$(cd $(TF_DIR) && terraform output -json ecr_repository_urls 2>/dev/null | jq -r '."smartops/crashy-app" // empty'); \
	  [ -n "$$REPO" ] || { echo "$(RED)✘ ecr_repository_urls missing — apply Module 3 first$(RESET)"; exit 1; }; \
	  echo "$(CYAN)==>$(RESET) tag + push to $$REPO:$(IMAGE_TAG) and :git-$(GIT_SHA)"; \
	  docker tag crashy-app:$(IMAGE_TAG)      "$$REPO:$(IMAGE_TAG)"; \
	  docker tag crashy-app:git-$(GIT_SHA)    "$$REPO:git-$(GIT_SHA)"; \
	  docker push "$$REPO:$(IMAGE_TAG)"; \
	  docker push "$$REPO:git-$(GIT_SHA)"

docker-build-controller: ## build the smartops-controller image locally (tag: :latest and :git-<sha>)
	@[ -d $(CONTROLLER_DIR) ] || { echo "$(CONTROLLER_DIR) not found"; exit 1; }
	@echo "$(CYAN)==>$(RESET) docker build $(CONTROLLER_DIR) → smartops-controller:$(IMAGE_TAG), :git-$(GIT_SHA)"
	@docker build \
	  -t smartops-controller:$(IMAGE_TAG) \
	  -t smartops-controller:git-$(GIT_SHA) \
	  $(CONTROLLER_DIR)

docker-push-controller: ecr-login docker-build-controller ## build + tag + push controller to ECR
	@REPO=$$(cd $(TF_DIR) && terraform output -json ecr_repository_urls 2>/dev/null | jq -r '."smartops/controller" // empty'); \
	  [ -n "$$REPO" ] || { echo "$(RED)✘ ecr_repository_urls['smartops/controller'] missing — apply Module 4 first$(RESET)"; exit 1; }; \
	  echo "$(CYAN)==>$(RESET) tag + push to $$REPO:$(IMAGE_TAG) and :git-$(GIT_SHA)"; \
	  docker tag smartops-controller:$(IMAGE_TAG)   "$$REPO:$(IMAGE_TAG)"; \
	  docker tag smartops-controller:git-$(GIT_SHA) "$$REPO:git-$(GIT_SHA)"; \
	  docker push "$$REPO:$(IMAGE_TAG)"; \
	  docker push "$$REPO:git-$(GIT_SHA)"

# ==== Module 5 — RCA pipeline (Lambda / DDB / EventBridge rule) ====
.PHONY: logs-rca invoke-rca-sample ddb-scan-incidents

logs-rca: ## tail the RCA Lambda's CloudWatch logs (Ctrl-C to stop)
	@LOG_GROUP=$$(cd $(TF_DIR) && terraform output -raw rca_lambda_log_group 2>/dev/null || echo "/aws/lambda/$(PROJECT)-rca-generator"); \
	  echo "$(CYAN)==>$(RESET) tailing $$LOG_GROUP"; \
	  aws logs tail "$$LOG_GROUP" --follow --format short --region $(REGION)

invoke-rca-sample: ## fire a fake IncidentDetected event onto the bus (E2E smoke test)
	@BUS=$$(cd $(TF_DIR) && terraform output -raw event_bus_name 2>/dev/null); \
	  [ -n "$$BUS" ] || { echo "$(RED)✘ event_bus_name output missing — apply Module 4 first$(RESET)"; exit 1; }; \
	  echo "$(CYAN)==>$(RESET) publishing sample IncidentDetected event to $$BUS"; \
	  aws events put-events --region $(REGION) --entries '[{"Source":"smartops.controller","DetailType":"IncidentDetected","EventBusName":"'"$$BUS"'","Detail":"{\"schemaVersion\":\"1.0\",\"incidentId\":\"smoke-'"$$(date +%s)"'\",\"namespace\":\"demo\",\"podName\":\"smoke-test-pod\",\"podUid\":\"smoke\",\"containerName\":\"c\",\"reason\":\"CrashLoopBackOff\",\"restartCount\":1,\"nodeName\":\"local\",\"zone\":null,\"timestamp\":\"'"$$(date -u +%Y-%m-%dT%H:%M:%SZ)"'\",\"message\":\"synthetic smoke test\",\"exitCode\":null,\"labels\":{}}"}]'

ddb-scan-incidents: ## dump every row in the smartops-incidents table (dev debug)
	@TABLE=$$(cd $(TF_DIR) && terraform output -raw incidents_table_name 2>/dev/null || echo "smartops-incidents"); \
	  echo "$(CYAN)==>$(RESET) scan $$TABLE"; \
	  aws dynamodb scan --table-name "$$TABLE" --region $(REGION) \
	    --query 'Items[*].[incidentId.S, reason.S, namespace.S, podName.S, ingestedAt.S, rcaStatus.S]' \
	    --output table

# ==== Module 7 — Remediator (Slack Ack receiver) ====
.PHONY: logs-remediator remediator-url put-signing-secret ddb-scan-acked

logs-remediator: ## tail the remediator Lambda's CloudWatch logs (Ctrl-C to stop)
	@LOG_GROUP=$$(cd $(TF_DIR) && terraform output -raw remediator_lambda_log_group 2>/dev/null || echo "/aws/lambda/$(PROJECT)-remediator"); \
	  echo "$(CYAN)==>$(RESET) tailing $$LOG_GROUP"; \
	  aws logs tail "$$LOG_GROUP" --follow --format short --region $(REGION)

remediator-url: ## print the public URL to paste into Slack app Interactivity settings
	@URL=$$(cd $(TF_DIR) && terraform output -raw remediator_function_url 2>/dev/null); \
	  [ -n "$$URL" ] || { echo "$(RED)✘ remediator_function_url output missing — apply Module 7 first$(RESET)"; exit 1; }; \
	  echo "$(GREEN)Slack app → Interactivity & Shortcuts → Request URL:$(RESET)"; \
	  echo "  $$URL"

put-signing-secret: ## write SLACK_SIGNING_SECRET (env var) to SSM (Module 7 setup)
	@[ -n "$$SLACK_SIGNING_SECRET" ] \
	  || { echo "$(RED)✘$(RESET) SLACK_SIGNING_SECRET env var is empty."; \
	       echo "  Recommended:  read -rs SLACK_SIGNING_SECRET; export SLACK_SIGNING_SECRET"; \
	       exit 1; }
	@bash scripts/put-secrets.sh --only-signing

ddb-scan-acked: ## dump rows where rcaStatus=acknowledged (who acked what)
	@TABLE=$$(cd $(TF_DIR) && terraform output -raw incidents_table_name 2>/dev/null || echo "smartops-incidents"); \
	  echo "$(CYAN)==>$(RESET) scan $$TABLE where rcaStatus=acknowledged"; \
	  aws dynamodb scan --table-name "$$TABLE" --region $(REGION) \
	    --filter-expression 'rcaStatus = :ack' \
	    --expression-attribute-values '{":ack":{"S":"acknowledged"}}' \
	    --query 'Items[*].[incidentId.S, reason.S, acknowledgedBy.S, acknowledgedAt.S]' \
	    --output table

# ==== Module 9 — MTTR Aggregator + Grafana observability ====
.PHONY: logs-mttr-aggregator invoke-mttr cloudwatch-metrics-mttr grafana-dashboard-url

logs-mttr-aggregator: ## tail the MTTR aggregator Lambda's CloudWatch logs (Ctrl-C to stop)
	@LOG_GROUP=$$(cd $(TF_DIR) && terraform output -raw mttr_aggregator_log_group 2>/dev/null || echo "/aws/lambda/$(PROJECT)-mttr-aggregator"); \
	  echo "$(CYAN)==>$(RESET) tailing $$LOG_GROUP"; \
	  aws logs tail "$$LOG_GROUP" --follow --format short --region $(REGION)

invoke-mttr: ## fire the MTTR aggregator NOW (bypass 5-min schedule)
	@FN=$$(cd $(TF_DIR) && terraform output -raw mttr_aggregator_lambda_name 2>/dev/null || echo "$(PROJECT)-mttr-aggregator"); \
	  echo "$(CYAN)==>$(RESET) invoking $$FN with a synthetic Scheduled Event"; \
	  TMP=$$(mktemp); \
	  aws lambda invoke --function-name "$$FN" --region $(REGION) \
	    --cli-binary-format raw-in-base64-out \
	    --payload '{"source":"aws.events","detail-type":"Scheduled Event","time":"'"$$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' \
	    "$$TMP" >/dev/null && \
	    echo "$(GREEN)response:$(RESET)" && cat "$$TMP" && echo "" && rm -f "$$TMP"

cloudwatch-metrics-mttr: ## list every metric the aggregator has emitted to CloudWatch
	@NS=$$(cd $(TF_DIR) && terraform output -raw mttr_metric_namespace 2>/dev/null || echo "SmartOps"); \
	  echo "$(CYAN)==>$(RESET) metrics in namespace $$NS"; \
	  aws cloudwatch list-metrics --namespace "$$NS" --region $(REGION) \
	    --query 'Metrics[*].[MetricName, join(`,`, Dimensions[*].Value) || `-`]' \
	    --output table

grafana-dashboard-url: ## print the pre-scoped CloudWatch Logs Insights URL used by the Grafana breakout panels
	@cd $(TF_DIR) && terraform output -raw rca_lambda_log_group_insights_url 2>/dev/null \
	  || echo "$(RED)✘ output missing — apply Module 9 first$(RESET)"

# ==== Verification ====
.PHONY: verify check-orphans lint validate test check

verify: ## run health-check script (module-aware; safe on empty state). Pass extra flags via ARGS="…"
	@bash scripts/verify.sh $(ARGS)

check-orphans: ## fail if any billable AWS resource still exists
	@bash scripts/check-orphans.sh

lint: ## lint everything (python, dockerfile, terraform, yaml, shell)
	@bash scripts/lint.sh

validate: ## static validation — terraform validate + helm lint (no AWS calls)
	@bash scripts/validate.sh

test: ## run all unit tests via poetry+pytest
	@bash scripts/test.sh

check: lint validate test ## umbrella target for CI: lint + validate + test
	@echo -e "$(GREEN)✔ all checks passed$(RESET)"

# ==== Local-only (kind) — zero AWS cost, works offline ====
# Full local demo of Modules 1-3 (K3s + crashy-app + anti-affinity) using
# kind + a local Docker registry. Modules 4+ (Lambda, EventBridge, SSM) are
# AWS-only and still need `make up` on real AWS to demo end-to-end.
.PHONY: local-up local-down local-status devcontainer-verify

local-up: ## spin up a local kind cluster + registry + crashy-app (no AWS)
	@bash scripts/local-up.sh

local-down: ## tear down the local kind cluster + registry
	@bash scripts/local-down.sh

local-status: ## show the local cluster + registry state
	@echo "$(CYAN)==> local registry:$(RESET)"
	@docker inspect -f '{{.State.Status}}: {{.Name}}' kind-registry 2>/dev/null || echo "  (not running)"
	@echo ""
	@echo "$(CYAN)==> kind clusters:$(RESET)"
	@kind get clusters 2>/dev/null || echo "  (kind CLI missing or no clusters)"
	@echo ""
	@if [ -f $$HOME/.kube/config-smartops-local ]; then \
	  echo "$(CYAN)==> local nodes:$(RESET)"; \
	  KUBECONFIG=$$HOME/.kube/config-smartops-local kubectl get nodes 2>/dev/null \
	    -o custom-columns=NAME:.metadata.name,ZONE:.metadata.labels.topology\\.kubernetes\\.io/zone,STATUS:.status.conditions[?\(@.type==\"Ready\"\)].status \
	    || echo "  (unreachable)"; \
	  echo ""; \
	  echo "$(CYAN)==> local pods (demo namespace):$(RESET)"; \
	  KUBECONFIG=$$HOME/.kube/config-smartops-local kubectl -n $(NAMESPACE) get pods 2>/dev/null || echo "  (no pods)"; \
	else \
	  echo "$(YELLOW)!  no local kubeconfig at $$HOME/.kube/config-smartops-local — run 'make local-up' first$(RESET)"; \
	fi

devcontainer-verify: ## re-run the devcontainer postCreate check (verifies every CLI)
	@bash .devcontainer/postCreate.sh

# ==== Chaos + demo ====
.PHONY: chaos-crash chaos-oom chaos-error chaos-slow chaos-info chaos-spread \
        demo demo-dry-run demo-reset pre-demo-check

chaos-crash: ## trigger CrashLoopBackOff in crashy-app
	@bash scripts/chaos.sh crash
chaos-oom: ## trigger OOMKilled in crashy-app
	@bash scripts/chaos.sh oom
chaos-error: ## trigger 500 in crashy-app
	@bash scripts/chaos.sh error
chaos-slow: ## trigger latency injection (5000ms default)
	@bash scripts/chaos.sh slow
chaos-info: ## print each crashy-app replica's pod / node / zone
	@bash scripts/chaos.sh info
chaos-spread: ## assert crashy-app replicas are spread across zones (verifies Module 3 anti-affinity)
	@bash scripts/chaos.sh spread

demo: ## run the ~90-sec scripted end-to-end demo (used for the Loom video)
	@bash scripts/demo.sh
demo-dry-run: ## same demo but skips chaos + AWS mutations (rehearsal mode)
	@bash scripts/demo.sh --dry-run
demo-reset: ## roll crashy-app back to healthy replicas (safe between takes)
	@bash scripts/demo.sh --reset
pre-demo-check: ## one-shot read-only health check before recording the Loom
	@bash scripts/pre-demo-check.sh

# ==== Cost tracking ====
.PHONY: cost cost-by-service

cost: ## show current-month AWS spend (unblended)
	@aws ce get-cost-and-usage \
	  --time-period Start=$$(date +%Y-%m-01),End=$$(date +%F) \
	  --granularity MONTHLY --metrics UnblendedCost \
	  --query 'ResultsByTime[0].Total.UnblendedCost' --output json

cost-by-service: ## current-month AWS spend grouped by service
	@aws ce get-cost-and-usage \
	  --time-period Start=$$(date +%Y-%m-01),End=$$(date +%F) \
	  --granularity MONTHLY --metrics UnblendedCost \
	  --group-by Type=DIMENSION,Key=SERVICE \
	  --query 'ResultsByTime[0].Groups[?to_number(Metrics.UnblendedCost.Amount)>`0.0`]' \
	  --output table

# ==== Sanity ====
.PHONY: whoami

whoami: ## show AWS identity + region + kubectl context
	@aws sts get-caller-identity
	@aws configure get region --profile $(AWS_PROFILE) 2>/dev/null || echo "(no default region on profile)"
	@kubectl config current-context 2>/dev/null || echo "(no kubectl context)"

# ==== Full project retirement ====
.PHONY: nuke

nuke: ## PERMANENT: delete EVERYTHING including tf-state, secrets, IAM user
	@bash scripts/nuke.sh
