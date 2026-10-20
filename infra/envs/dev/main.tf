# Root of the dev environment. Wires the four reusable modules together.
#
# This file is intentionally slim: it declares what modules to invoke, what
# to pass to them, and how they depend on each other. All actual resource
# definitions live in infra/modules/*.

# ---- Latest Ubuntu 24.04 LTS AMI (Canonical, amd64) -----------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---- Networking -----------------------------------------------------------
module "vpc" {
  source = "../../modules/vpc"

  project             = var.project
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
}

# ---- Security groups ------------------------------------------------------
module "security_group" {
  source = "../../modules/security-group"

  project = var.project
  vpc_id  = module.vpc.vpc_id
}

# ---- EventBridge custom bus (Module 4) ----------------------------------
# Created BEFORE the IAM module so its ARN can be passed into the node
# policy (attach_controller_policy = true).
module "eventbridge" {
  source = "../../modules/eventbridge"

  bus_name       = var.event_bus_name
  enable_archive = var.enable_event_archive
  tags = {
    project = var.project
    env     = var.env
    owner   = var.owner
    module  = "04-controller"
  }
}

# ---- IAM role + instance profile -----------------------------------------
module "iam" {
  source = "../../modules/iam"

  project                   = var.project
  env                       = var.env
  ssm_kubeconfig_param_name = var.ssm_kubeconfig_param_name
  attach_ecr_read_only      = true # Module 3: nodes must pull images from private ECR
  attach_controller_policy  = true # Module 4: controller pod publishes to EventBridge via node IMDS
  event_bus_arn             = module.eventbridge.bus_arn
}

# ---- ECR repositories (Module 3) -----------------------------------------
# Private repos, scan-on-push enabled, lifecycle policies auto-prune old
# images. See infra/modules/ecr for the exact policy shape.
module "ecr" {
  source = "../../modules/ecr"

  project          = var.project
  repository_names = var.ecr_repository_names
}

# ---- K3s server node (control plane) — always exactly one --------------
module "k3s_server" {
  source = "../../modules/k3s"

  project              = var.project
  env                  = var.env
  role                 = "server"
  ami_id               = data.aws_ami.ubuntu.id
  instance_type        = var.instance_type
  root_volume_gb       = var.root_volume_gb
  subnet_id            = module.vpc.public_subnet_ids[0]
  security_group_ids   = [module.security_group.k3s_sg_id]
  instance_profile     = module.iam.instance_profile_name
  ssm_kubeconfig_param = var.ssm_kubeconfig_param_name
  region               = var.region
}

# ---- K3s agent node (worker, AZ-b) — added in Module 2 -----------------
# Uses the same reusable k3s module with role="agent".
# The agent's cloud-init reads /smartops/<env>/k3s_join_token and
# /smartops/<env>/k3s_server_url (written by the server on first boot) and
# then runs the standard K3s agent installer.
#
# Toggle with var.enable_agent (default true). Setting it false takes us
# back to the Module 1 single-node baseline — useful for cost testing.
module "k3s_agent" {
  source = "../../modules/k3s"
  count  = var.enable_agent ? 1 : 0

  project              = var.project
  env                  = var.env
  role                 = "agent"
  ami_id               = data.aws_ami.ubuntu.id
  instance_type        = var.agent_instance_type
  root_volume_gb       = var.root_volume_gb
  subnet_id            = module.vpc.public_subnet_ids[1]
  security_group_ids   = [module.security_group.k3s_sg_id]
  instance_profile     = module.iam.instance_profile_name
  ssm_kubeconfig_param = var.ssm_kubeconfig_param_name
  region               = var.region

  # Orders the agent after the server's EC2 instance (not after its
  # bootstrap): the agent's cloud-init waits up to 5 min for this server to
  # stamp its ID into SSM before reading the join token + URL.
  server_instance_id = module.k3s_server.instance_id
}

# ==========================================================================
# Module 5 — RCA pipeline: EventBridge rule → Lambda → DynamoDB (+ Slack)
# ==========================================================================
# When the controller (Module 4) publishes an `IncidentDetected` event to
# the smartops-dev bus, a rule fires the rca-generator Lambda. The Lambda:
#   1. Parses the incident (schema v1.0 from docs/modules/04-controller.md).
#   2. Writes a row to DynamoDB `smartops-incidents` (idempotent by incidentId).
#   3. Sends a plain-text Slack ping to the webhook stored in SSM.
# Groq LLM enrichment + rich Block Kit formatting land in Module 6.

# ---- DynamoDB table for persisted incidents -------------------------------
module "dynamodb_incidents" {
  source = "../../modules/dynamodb"

  table_name    = var.incidents_table_name
  hash_key_name = "incidentId"
  hash_key_type = "S"
  enable_pitr   = false # Dev — no long-term recovery needed
  enable_ttl    = false # Keep everything visible for debugging
  tags = {
    project = var.project
    env     = var.env
    owner   = var.owner
    module  = "05-rca-lambda"
  }
}

# ---- Locals for the RCA Lambda -------------------------------------------
locals {
  # SSM parameter paths that the Lambda reads at cold-start. Kept as a local
  # so the IAM policy + the Lambda's env vars agree on the exact same paths.
  ssm_slack_webhook_path        = "/smartops/${var.env}/slack_webhook"
  ssm_groq_key_path             = "/smartops/${var.env}/groq_api_key"
  ssm_slack_signing_secret_path = "/smartops/${var.env}/slack_signing_secret"

  ssm_secret_arns = [
    format("arn:aws:ssm:%s:%s:parameter%s",
      var.region,
      data.aws_caller_identity.current.account_id,
      local.ssm_slack_webhook_path,
    ),
    format("arn:aws:ssm:%s:%s:parameter%s",
      var.region,
      data.aws_caller_identity.current.account_id,
      local.ssm_groq_key_path,
    ),
  ]

  # Module 7 — remediator secrets (kept as a separate list so the RCA
  # Lambda's IAM policy stays tight to only what IT needs).
  ssm_remediator_secret_arns = [
    format("arn:aws:ssm:%s:%s:parameter%s",
      var.region,
      data.aws_caller_identity.current.account_id,
      local.ssm_slack_signing_secret_path,
    ),
  ]
}

data "aws_caller_identity" "current" {}

# ---- RCA Lambda (source zipped from ../../../lambdas/rca-generator/src) ----
module "lambda_rca" {
  source = "../../modules/lambda"

  function_name      = "${var.project}-rca-generator"
  source_dir         = "${path.module}/../../../lambdas/rca-generator/src"
  handler            = "rca_generator.handler.lambda_handler"
  runtime            = "python3.12"
  timeout_seconds    = var.rca_lambda_timeout_seconds
  memory_mb          = 256
  log_retention_days = 14

  environment_variables = {
    # Never put SECRETS here — these are just non-secret operational config.
    INCIDENTS_TABLE_NAME    = module.dynamodb_incidents.table_name
    SSM_SLACK_WEBHOOK_PATH  = local.ssm_slack_webhook_path
    SSM_GROQ_KEY_PATH       = local.ssm_groq_key_path
    SLACK_ENABLED           = var.slack_notifications_enabled ? "true" : "false"
    SLACK_BLOCKS_ENABLED    = var.slack_blocks_enabled ? "true" : "false"
    LLM_ENABLED             = var.llm_enabled ? "true" : "false"
    LLM_MODEL               = var.llm_model
    LLM_TIMEOUT_SECONDS     = tostring(var.llm_timeout_seconds)
    LLM_MAX_TOKENS          = tostring(var.llm_max_tokens)
    LOG_LEVEL               = "INFO"
    SCHEMA_VERSION_EXPECTED = "1.0"
  }

  additional_policy_statements = [
    {
      Sid    = "PersistIncidentsToDynamo"
      Effect = "Allow"
      Action = [
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:GetItem",
      ]
      Resource = [module.dynamodb_incidents.table_arn]
    },
    {
      Sid    = "ReadSecretsFromSSM"
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
      ]
      Resource = local.ssm_secret_arns
    },
    {
      Sid    = "DecryptSSMSecureString"
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
      ]
      Resource = ["*"]
      Condition = {
        StringEquals = {
          "kms:ViaService" = "ssm.${var.region}.amazonaws.com"
        }
      }
    },
  ]

  tags = {
    project = var.project
    env     = var.env
    owner   = var.owner
    module  = "05-rca-lambda"
  }
}

# ---- EventBridge rule: IncidentDetected → RCA Lambda ---------------------
# Filters ONLY the events published by our controller (source =
# smartops.controller, detail-type = IncidentDetected). Anything else on the
# bus is ignored — future modules can add more rules alongside this one.
resource "aws_cloudwatch_event_rule" "incident_detected" {
  name           = "${var.project}-incident-detected"
  description    = "Fires the RCA Lambda when the controller publishes an IncidentDetected event."
  event_bus_name = module.eventbridge.bus_name

  event_pattern = jsonencode({
    source        = ["smartops.controller"]
    "detail-type" = ["IncidentDetected"]
  })

  tags = {
    project = var.project
    env     = var.env
    owner   = var.owner
    module  = "05-rca-lambda"
  }
}

resource "aws_cloudwatch_event_target" "rca_lambda" {
  rule           = aws_cloudwatch_event_rule.incident_detected.name
  event_bus_name = module.eventbridge.bus_name
  target_id      = "rca-generator"
  arn            = module.lambda_rca.function_arn

  # No dead-letter queue in Module 5.0 — EventBridge retries failed
  # invocations for 24h automatically. DLQ + on-failure destination
  # land in Module 7 (Remediator + safety guardrails).
}

# Grants EventBridge permission to invoke the Lambda. Scoped tightly to
# THIS rule's ARN — no other principal can invoke the function.
resource "aws_lambda_permission" "eventbridge_invoke_rca" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_rca.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.incident_detected.arn
}

# ==========================================================================
# Module 7 — Remediator: Slack Ack button receiver
# ==========================================================================
# When a user clicks the "Acknowledge" button on the Block Kit card that
# Module 6 posted, Slack POSTs a `block_actions` payload to this Lambda's
# HTTPS URL. The Lambda:
#   1. Verifies the HMAC signature (SSM SecureString: slack_signing_secret).
#   2. Updates the DDB row: rcaStatus = "acknowledged" + acknowledgedBy/At.
#   3. For whitelisted reasons, PutEvents a `RemediationRequested` event
#      onto the SmartOps bus for Module 7.1's executor to consume.
#   4. Replies with a JSON body that replaces the button with a footer.
#
# Design choice: Lambda Function URL (not API Gateway). One endpoint, no
# API Gateway resource, still HTTPS + IAM-optional. Saves a resource + a
# potential API Gateway free-tier line item.

module "lambda_remediator" {
  source = "../../modules/lambda"

  function_name      = "${var.project}-remediator"
  source_dir         = "${path.module}/../../../lambdas/remediator/src"
  handler            = "remediator.handler.lambda_handler"
  runtime            = "python3.12"
  timeout_seconds    = var.remediator_lambda_timeout_seconds
  memory_mb          = 256
  log_retention_days = 14

  environment_variables = {
    INCIDENTS_TABLE_NAME          = module.dynamodb_incidents.table_name
    SSM_SLACK_SIGNING_SECRET_PATH = local.ssm_slack_signing_secret_path
    EVENT_BUS_NAME                = module.eventbridge.bus_name
    ALLOWED_REMEDIATION_REASONS   = var.allowed_remediation_reasons
    REPLAY_WINDOW_SECONDS         = tostring(var.slack_replay_window_seconds)
    LOG_LEVEL                     = "INFO"
  }

  additional_policy_statements = [
    {
      Sid    = "AcknowledgeIncidentInDynamo"
      Effect = "Allow"
      Action = [
        "dynamodb:UpdateItem",
        "dynamodb:GetItem",
      ]
      Resource = [module.dynamodb_incidents.table_arn]
    },
    {
      Sid    = "PublishRemediationRequested"
      Effect = "Allow"
      Action = [
        "events:PutEvents",
      ]
      Resource = [module.eventbridge.bus_arn]
    },
    {
      Sid    = "ReadSigningSecretFromSSM"
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
      ]
      Resource = local.ssm_remediator_secret_arns
    },
    {
      Sid    = "DecryptSSMSecureString"
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
      ]
      Resource = ["*"]
      Condition = {
        StringEquals = {
          "kms:ViaService" = "ssm.${var.region}.amazonaws.com"
        }
      }
    },
  ]

  tags = {
    project = var.project
    env     = var.env
    owner   = var.owner
    module  = "07-remediator"
  }
}

# Public HTTPS URL the Slack app posts to. No IAM auth (Slack can't sign
# AWS SigV4) — auth is HMAC-verified inside the Lambda from the signing
# secret. CORS is intentionally open because Slack-Slack traffic isn't
# subject to browser origin checks.
resource "aws_lambda_function_url" "remediator" {
  function_name      = module.lambda_remediator.function_name
  authorization_type = "NONE"

  cors {
    allow_origins = ["*"]
    allow_methods = ["POST"]
    allow_headers = [
      "content-type",
      "x-slack-signature",
      "x-slack-request-timestamp",
    ]
    max_age = 300
  }
}

# ==========================================================================
# Module 9 — MTTR Aggregator: DDB scan → CloudWatch custom metrics
# ==========================================================================
# Every 5 minutes, an EventBridge Scheduler rule fires this Lambda. The
# Lambda scans the `smartops-incidents` DDB table for rows ingested in the
# last `mttr_window_minutes` and publishes exactly 5 no-dimension custom
# metrics (IncidentCount, AckedIncidentCount, AckRatePercent,
# LLMSuccessRatePercent, MTTRSecondsAvg) to the CloudWatch namespace
# `SmartOps`. Grafana Cloud reads them via its CloudWatch data source.
#
# Free tier compliance:
#   - Lambda invocations: 12/hr × 720 h = 8,640/mo — well under 1M free
#   - Lambda compute: 128 MB × 300 ms × 8,640 ≈ 332 GB-s — under 400 k free
#   - CloudWatch custom metrics: 5 series — under 10 free
#   - DDB Scan: full scan on ~100 rows, 12/hr — under 25 RCU on-demand free
#
# Per-reason breakouts intentionally live in Logs Insights queries on the
# rca-generator log group, not in custom metrics — that split keeps the
# metric count inside the 10-series free tier ceiling.

module "lambda_mttr_aggregator" {
  source = "../../modules/lambda"

  function_name      = "${var.project}-mttr-aggregator"
  source_dir         = "${path.module}/../../../lambdas/mttr-aggregator/src"
  handler            = "mttr_aggregator.handler.lambda_handler"
  runtime            = "python3.12"
  timeout_seconds    = var.mttr_lambda_timeout_seconds
  memory_mb          = 128 # aggregator is cheap — smallest tier is enough
  log_retention_days = 14

  environment_variables = {
    INCIDENTS_TABLE_NAME = module.dynamodb_incidents.table_name
    METRIC_NAMESPACE     = var.mttr_metric_namespace
    WINDOW_MINUTES       = tostring(var.mttr_window_minutes)
    LOG_LEVEL            = "INFO"
  }

  additional_policy_statements = [
    {
      Sid    = "ScanIncidentsTable"
      Effect = "Allow"
      Action = [
        "dynamodb:Scan",
      ]
      Resource = [module.dynamodb_incidents.table_arn]
    },
    {
      # PutMetricData does not accept resource-level ARNs; scope via
      # cloudwatch:namespace condition to lock us to the SmartOps namespace.
      Sid    = "PublishSmartOpsMetrics"
      Effect = "Allow"
      Action = [
        "cloudwatch:PutMetricData",
      ]
      Resource = ["*"]
      Condition = {
        StringEquals = {
          "cloudwatch:namespace" = var.mttr_metric_namespace
        }
      }
    },
  ]

  tags = {
    project = var.project
    env     = var.env
    owner   = var.owner
    module  = "09-mttr-aggregator"
  }
}

# EventBridge schedule — fire the aggregator every 5 min on the DEFAULT
# bus (schedule rules only run on the default bus; custom bus events
# still go to smartops-<env>).
resource "aws_cloudwatch_event_rule" "mttr_schedule" {
  name                = "${var.project}-mttr-aggregate"
  description         = "Fires the MTTR aggregator Lambda every 5 minutes."
  schedule_expression = var.mttr_schedule_expression

  tags = {
    project = var.project
    env     = var.env
    owner   = var.owner
    module  = "09-mttr-aggregator"
  }
}

resource "aws_cloudwatch_event_target" "mttr_lambda" {
  rule      = aws_cloudwatch_event_rule.mttr_schedule.name
  target_id = "mttr-aggregator"
  arn       = module.lambda_mttr_aggregator.function_arn
}

resource "aws_lambda_permission" "eventbridge_invoke_mttr" {
  statement_id  = "AllowExecutionFromScheduler"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_mttr_aggregator.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.mttr_schedule.arn
}
