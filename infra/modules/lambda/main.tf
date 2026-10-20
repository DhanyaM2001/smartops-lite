# Reusable AWS Lambda module — Python source only.
#
# Handles:
#   1. Zipping a source tree with `data "archive_file"`.
#   2. Creating the CloudWatch Log Group up-front (with retention) so we
#      never pay for indefinite log retention (the default when the Lambda
#      auto-creates its log group).
#   3. Building the execution role: AWSLambdaBasicExecutionRole (managed)
#      + one caller-supplied inline policy carrying ALL the extra actions
#      the function needs (DDB write, SSM read, etc.).
#   4. Creating the function itself.
#
# Explicit NON-goals:
#   - No Lambda layers. Adds complexity without value for a single-file
#     boto3-only handler.
#   - No VPC attachment. The RCA Lambda calls only public AWS endpoints
#     (SSM, DDB, EventBridge) + Slack — no need for private subnet + NAT.
#   - No dead-letter queue in Module 5.0. EventBridge itself will retry
#     failed invocations for 24h; we add a proper DLQ in Module 7.

# ---- 1. Zip the source tree ------------------------------------------------
data "archive_file" "source" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.artifacts/${var.function_name}.zip"

  # Exclude tests + dev files from the deployment package (keeps cold start
  # fast + shrinks the artifact). Callers can pre-clean __pycache__ if it
  # matters.
  excludes = [
    "tests",
    "__pycache__",
    "*.pyc",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    "pyproject.toml",
    "poetry.lock",
  ]
}

# ---- 2. Log group (created BEFORE function so retention applies day-one) ---
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "/aws/lambda/${var.function_name}"
  })
}

# ---- 3. Execution role -----------------------------------------------------
resource "aws_iam_role" "lambda" {
  name = "${var.function_name}-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name = "${var.function_name}-exec"
  })
}

# Basic execution: create log stream + PutLogEvents on THIS log group.
resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Caller-supplied inline policy (skipped if the caller has nothing to add).
resource "aws_iam_role_policy" "inline" {
  count = length(var.additional_policy_statements) > 0 ? 1 : 0
  name  = "${var.function_name}-inline"
  role  = aws_iam_role.lambda.id

  # Optional attributes arrive as null (e.g. "Condition": null), which IAM
  # rejects as MalformedPolicyDocument — drop them before encoding.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for s in var.additional_policy_statements : { for k, v in s : k => v if v != null }
    ]
  })
}

# ---- 4. The function itself ------------------------------------------------
resource "aws_lambda_function" "this" {
  function_name = var.function_name
  role          = aws_iam_role.lambda.arn
  handler       = var.handler
  runtime       = var.runtime
  timeout       = var.timeout_seconds
  memory_size   = var.memory_mb

  filename         = data.archive_file.source.output_path
  source_code_hash = data.archive_file.source.output_base64sha256

  # Environment variables are visible in the AWS console — DON'T put secrets
  # here. Secrets should be fetched from SSM SecureString at cold start.
  environment {
    variables = var.environment_variables
  }

  # x86_64 (default) — arm64 is cheaper but the free tier covers both, and
  # some Python wheels lag on arm64. Not worth the risk for a demo project.

  tags = merge(var.tags, {
    Name = var.function_name
  })

  depends_on = [
    aws_iam_role_policy_attachment.basic,
    aws_cloudwatch_log_group.lambda,
  ]
}
