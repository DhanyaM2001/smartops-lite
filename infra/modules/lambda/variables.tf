variable "function_name" {
  description = "AWS-visible Lambda function name."
  type        = string
}

variable "source_dir" {
  description = <<-EOT
    Absolute or path-module-relative filesystem path to the Lambda source
    tree. Every file below this directory (except tests/__pycache__/etc.)
    is zipped into the deployment artifact.
  EOT
  type        = string
}

variable "handler" {
  description = "Lambda handler in module.function form (e.g. rca_generator.handler.lambda_handler)."
  type        = string
  default     = "handler.lambda_handler"
}

variable "runtime" {
  description = "Lambda runtime. Pinned to python3.12 unless overridden."
  type        = string
  default     = "python3.12"
}

variable "timeout_seconds" {
  description = "Function timeout in seconds (max 900)."
  type        = number
  default     = 30

  validation {
    condition     = var.timeout_seconds > 0 && var.timeout_seconds <= 900
    error_message = "timeout_seconds must be between 1 and 900."
  }
}

variable "memory_mb" {
  description = "Memory allocation in MB. CPU is proportional to this."
  type        = number
  default     = 256
}

variable "environment_variables" {
  description = <<-EOT
    Env vars exposed to the function. DO NOT put secrets here — they're
    visible in the AWS console. Fetch secrets from SSM at cold start.
  EOT
  type        = map(string)
  default     = {}
}

variable "additional_policy_statements" {
  description = <<-EOT
    IAM policy statements bundled into a single inline policy on the
    execution role. Each element is a Statement block (Sid/Effect/Action/
    Resource/Condition). Pass [] to skip creating the inline policy.

    Resource is `list(string)` for consistency — wrap single ARNs in a
    one-element list. IAM's JSON accepts either form; keeping it uniform
    lets Terraform build a single list<object> without mixed element types.
  EOT
  type = list(object({
    Sid       = optional(string)
    Effect    = string
    Action    = list(string)
    Resource  = list(string)
    Condition = optional(map(map(string)))
  }))
  default = []
}

variable "log_retention_days" {
  description = <<-EOT
    CloudWatch Logs retention in days. AWS defaults to 'never expire' which
    slowly accrues storage cost — we pin to 14 for dev.
  EOT
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}
