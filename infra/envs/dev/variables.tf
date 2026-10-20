variable "project" {
  description = "Short project name — used as a prefix for resource names."
  type        = string
  default     = "smartops-lite"
}

variable "env" {
  description = "Environment tag (dev/staging/prod)."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Owner tag — appears on every resource for accountability."
  type        = string
  default     = "dhanym"
}

variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "ap-south-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the two public subnets (AZ-a, AZ-b)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "instance_type" {
  description = "EC2 instance type for the K3s server node (t3.micro is free-tier eligible)."
  type        = string
  default     = "t3.micro"
}

variable "agent_instance_type" {
  description = "EC2 instance type for K3s agent node(s). Kept separate so we can size workers differently later."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_gb" {
  description = "Size of the root EBS volume in GB. Default 15 keeps 2-node cluster within the 30 GB EBS free-tier ceiling (15 + 15 = 30)."
  type        = number
  default     = 15
}

variable "enable_agent" {
  description = "Whether to deploy the K3s agent node (Module 2). Set false to fall back to single-node (Module 1)."
  type        = bool
  default     = true
}

variable "ssm_kubeconfig_param_name" {
  description = "SSM parameter path where cloud-init uploads the kubeconfig."
  type        = string
  default     = "/smartops/dev/kubeconfig"
}

# ---- Module 3 — ECR repos for our container images -----------------------
variable "ecr_repository_names" {
  description = <<-EOT
    Private ECR repositories to create for this environment. Path-style
    names ("smartops/crashy-app") group images under a project prefix.
    Add new repos here as future modules ship their images.
  EOT
  type        = list(string)
  default = [
    "smartops/crashy-app", # Module 3
    "smartops/controller", # Module 4
  ]
}

# ---- Module 4 — EventBridge custom bus for incidents ---------------------
variable "event_bus_name" {
  description = "Name of the custom EventBridge bus the controller writes to (defaults to <project>-<env>)."
  type        = string
  default     = "smartops-dev"
}

variable "enable_event_archive" {
  description = "Enable a 30-day archive on the event bus (used by Module 12 for replay). Off by default."
  type        = bool
  default     = false
}

# ---- Module 5 — RCA Lambda + DynamoDB ------------------------------------
variable "incidents_table_name" {
  description = "Name of the DynamoDB table that stores persisted incident rows."
  type        = string
  default     = "smartops-incidents"
}

variable "slack_notifications_enabled" {
  description = <<-EOT
    Toggle for the Slack ping the RCA Lambda sends on every incident.
    Even when true, the Lambda still runs to completion if the webhook is
    missing/invalid — it logs an error and moves on so DDB writes never
    fail because of a Slack outage.
  EOT
  type        = bool
  default     = true
}

# ---- Module 6 — Groq LLM + Block Kit Slack ------------------------------
variable "slack_blocks_enabled" {
  description = <<-EOT
    Send Slack messages as Block Kit cards (severity color + RCA block +
    Acknowledge button). Set false to fall back to the Module 5.0 plain-text
    format (useful if the webhook is a legacy #alerts channel).
  EOT
  type        = bool
  default     = true
}

variable "llm_enabled" {
  description = <<-EOT
    Call Groq LLM to generate RCA text. When false, the RCA Lambda skips
    the network call and writes a placeholder to DDB — useful for local
    testing or if the Groq quota is exhausted.
  EOT
  type        = bool
  default     = true
}

variable "llm_model" {
  description = <<-EOT
    Groq model id (list yours: GET https://api.groq.com/openai/v1/models).
    Reasoning models spend part of llm_max_tokens thinking before the
    answer, so pick one that finishes well inside the cap:
      qwen/qwen3.8-27b      — default; ~65 tokens for a 2-sentence RCA
      openai/gpt-oss-120b   — also works, but ~140 of the 200 tokens
    openai/gpt-oss-20b runs out of tokens mid-answer at the 200 cap.
    Swap without redeploying code by updating this and running `tf-apply`.
  EOT
  type        = string
  default     = "qwen/qwen3.8-27b"
}

variable "llm_timeout_seconds" {
  description = "Per-invocation HTTP timeout for the Groq call. Must be < rca_lambda_timeout_seconds."
  type        = number
  default     = 10
}

variable "llm_max_tokens" {
  description = "Cap on Groq response length. 200 comfortably fits 2-sentence RCAs; higher costs more."
  type        = number
  default     = 200
}

variable "rca_lambda_timeout_seconds" {
  description = <<-EOT
    Total Lambda timeout. Must budget the LLM call (llm_timeout_seconds) +
    DDB write (~200ms) + Slack POST (~500ms) + cold-start overhead. Bumped
    30s → 60s in Module 6 to give LLM headroom.
  EOT
  type        = number
  default     = 60
}

# ---- Module 7 — Remediator (Slack Ack receiver) --------------------------
variable "allowed_remediation_reasons" {
  description = <<-EOT
    Comma-separated list of incident reasons that trigger a
    RemediationRequested event on the SmartOps bus when acknowledged.
    Empty (default) = Module 7.0 "ack-only" mode.

    Module 7.1 will subscribe to these events and execute safe actions
    (e.g. `kubectl patch` to bump memory limits for OOMKilled).

    Recommended starter set once 7.1 lands: "OOMKilled".
  EOT
  type        = string
  default     = ""
}

variable "slack_replay_window_seconds" {
  description = <<-EOT
    Reject Slack interaction requests whose X-Slack-Request-Timestamp is
    more than this many seconds old (or in the future). Slack's own docs
    recommend 300s (5min) — same value used here.
  EOT
  type        = number
  default     = 300
}

variable "remediator_lambda_timeout_seconds" {
  description = <<-EOT
    Total Lambda timeout for the remediator. Sized generously so a slow
    DDB / bus / EventBridge call doesn't cause Slack to see a 5xx and
    retry (Slack's own timeout is 3s — we should reply well within that).
  EOT
  type        = number
  default     = 10
}

# ---- Module 9 — MTTR Aggregator + Grafana --------------------------------
variable "mttr_metric_namespace" {
  description = <<-EOT
    CloudWatch namespace under which the aggregator publishes metrics.
    Kept as a variable so it can be swapped per env (dev / staging / prod)
    without editing IAM policy JSON. IAM cloudwatch:PutMetricData is
    scoped to this exact value via cloudwatch:namespace condition.
  EOT
  type        = string
  default     = "SmartOps"
}

variable "mttr_window_minutes" {
  description = <<-EOT
    How many minutes of DDB history each aggregator run scans. 60 min gives
    Grafana a 1-hour rolling view without needing a GSI on ingestedAt.
    Bump this if the demo table starts approaching thousands of rows.
  EOT
  type        = number
  default     = 60
}

variable "mttr_schedule_expression" {
  description = <<-EOT
    EventBridge schedule expression that fires the aggregator. Default is
    every 5 minutes:
      rate(5 minutes) → 12/hour → 8,640/mo → well inside Lambda free tier.
    Use rate(1 hour) if you want to be even more conservative.
  EOT
  type        = string
  default     = "rate(5 minutes)"
}

variable "mttr_lambda_timeout_seconds" {
  description = <<-EOT
    Total Lambda timeout for the MTTR aggregator. DDB scan on the demo
    table takes <500 ms and CloudWatch PutMetricData is <100 ms per batch
    — 30 s gives headroom for cold-start + retries without approaching
    the 15 min hard Lambda cap.
  EOT
  type        = number
  default     = 30
}
