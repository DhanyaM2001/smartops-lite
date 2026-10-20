# Outputs consumed by:
#   - The Makefile's `kube-config` target (uses kubeconfig_fetch_cmd)
#   - `scripts/verify.sh` (reads expected_node_count)
#   - Humans running `terraform output` to poke around
#
# Note: the agent's join token + server URL are NOT terraform outputs — the
# agent's cloud-init reads them from SSM directly. This keeps them off both
# the tfstate file and any developer laptop.

output "vpc_id" {
  description = "ID of the SmartOps VPC."
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the two public subnets (AZ-a, AZ-b)."
  value       = module.vpc.public_subnet_ids
}

output "k3s_server_instance_id" {
  description = "EC2 instance ID of the K3s server node."
  value       = module.k3s_server.instance_id
}

output "k3s_server_public_ip" {
  description = "Public IP of the K3s server node (used for API server tunneling)."
  value       = module.k3s_server.public_ip
}

output "k3s_server_private_ip" {
  description = "Private IP inside the VPC."
  value       = module.k3s_server.private_ip
}

# Agent outputs return null when enable_agent = false so downstream tooling
# can just check `!= null` instead of catching an error.
output "k3s_agent_instance_id" {
  description = "EC2 instance ID of the K3s agent node (null when enable_agent=false)."
  value       = try(module.k3s_agent[0].instance_id, null)
}

output "k3s_agent_public_ip" {
  description = "Public IP of the K3s agent node (null when enable_agent=false)."
  value       = try(module.k3s_agent[0].public_ip, null)
}

output "k3s_agent_private_ip" {
  description = "Private IP of the K3s agent node inside the VPC (null when enable_agent=false)."
  value       = try(module.k3s_agent[0].private_ip, null)
}

output "expected_node_count" {
  description = "How many K3s nodes should be Ready (used by verify.sh)."
  value       = 1 + (var.enable_agent ? 1 : 0)
}

output "iam_role_arn" {
  description = "ARN of the IAM role attached to K3s nodes."
  value       = module.iam.role_arn
}

output "ssm_kubeconfig_param" {
  description = "SSM parameter name where cloud-init uploads the kubeconfig."
  value       = var.ssm_kubeconfig_param_name
}

# Command a human runs locally to pull the kubeconfig from SSM.
# Used by `make kube-config`.
output "kubeconfig_fetch_cmd" {
  description = "Shell command that prints the kubeconfig YAML to stdout."
  value = format(
    "aws ssm get-parameter --name %s --with-decryption --query Parameter.Value --output text --region %s",
    var.ssm_kubeconfig_param_name,
    var.region,
  )
}

# Command a human runs locally to open a port-forward tunnel to the K3s
# API server. Kubeconfig points to https://127.0.0.1:6443 while this is up.
output "kube_api_tunnel_cmd" {
  description = "Start an SSM port-forward to reach the K3s API server."
  value = format(
    "aws ssm start-session --target %s --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"6443\"],\"localPortNumber\":[\"6443\"]}' --region %s",
    module.k3s_server.instance_id,
    var.region,
  )
}

# ---- Module 3 — ECR outputs --------------------------------------------
output "ecr_repository_urls" {
  description = "Map of ECR repo short name -> pushable URL (consumed by Makefile docker-push targets)."
  value       = module.ecr.repository_urls
}

output "ecr_registry_url" {
  description = "Base ECR registry URL for this AWS account/region — pass to `aws ecr get-login-password`."
  value       = format("%s.dkr.ecr.%s.amazonaws.com", module.ecr.registry_id, var.region)
}

# ---- Module 4 — EventBridge outputs ------------------------------------
output "event_bus_name" {
  description = "Name of the SmartOps custom EventBridge bus (consumed by the controller Helm chart)."
  value       = module.eventbridge.bus_name
}

output "event_bus_arn" {
  description = "ARN of the SmartOps custom EventBridge bus."
  value       = module.eventbridge.bus_arn
}

# ---- Module 5 — RCA pipeline outputs -----------------------------------
output "incidents_table_name" {
  description = "Name of the DynamoDB table storing persisted incidents."
  value       = module.dynamodb_incidents.table_name
}

output "incidents_table_arn" {
  description = "ARN of the incidents DynamoDB table."
  value       = module.dynamodb_incidents.table_arn
}

output "rca_lambda_name" {
  description = "Name of the RCA-generator Lambda function."
  value       = module.lambda_rca.function_name
}

output "rca_lambda_arn" {
  description = "ARN of the RCA-generator Lambda."
  value       = module.lambda_rca.function_arn
}

output "rca_lambda_log_group" {
  description = "CloudWatch Log Group holding RCA Lambda logs — pass to `aws logs tail`."
  value       = module.lambda_rca.log_group_name
}

output "incident_rule_name" {
  description = "Name of the EventBridge rule that fires the RCA Lambda."
  value       = aws_cloudwatch_event_rule.incident_detected.name
}

output "incident_rule_arn" {
  description = "ARN of the EventBridge rule for the RCA pipeline."
  value       = aws_cloudwatch_event_rule.incident_detected.arn
}

# ---- Module 7 — Remediator outputs -------------------------------------
output "remediator_lambda_name" {
  description = "Name of the remediator (Slack Ack receiver) Lambda."
  value       = module.lambda_remediator.function_name
}

output "remediator_lambda_arn" {
  description = "ARN of the remediator Lambda."
  value       = module.lambda_remediator.function_arn
}

output "remediator_lambda_log_group" {
  description = "CloudWatch Log Group holding remediator Lambda logs — pass to `aws logs tail`."
  value       = module.lambda_remediator.log_group_name
}

output "remediator_function_url" {
  description = "Public HTTPS URL to paste into the Slack app's Interactivity Request URL setting."
  value       = aws_lambda_function_url.remediator.function_url
}

output "ssm_slack_signing_secret_path" {
  description = "SSM SecureString path where the Slack signing secret is stored — `make put-secrets --only-signing` writes to this."
  value       = local.ssm_slack_signing_secret_path
}

# ---- Module 9 — MTTR Aggregator outputs --------------------------------
output "mttr_aggregator_lambda_name" {
  description = "Name of the MTTR aggregator Lambda function."
  value       = module.lambda_mttr_aggregator.function_name
}

output "mttr_aggregator_lambda_arn" {
  description = "ARN of the MTTR aggregator Lambda."
  value       = module.lambda_mttr_aggregator.function_arn
}

output "mttr_aggregator_log_group" {
  description = "CloudWatch Log Group holding MTTR aggregator logs — pass to `aws logs tail`."
  value       = module.lambda_mttr_aggregator.log_group_name
}

output "mttr_metric_namespace" {
  description = "CloudWatch namespace the aggregator publishes to (used by Grafana panels)."
  value       = var.mttr_metric_namespace
}

output "mttr_schedule_rule_name" {
  description = "Name of the EventBridge schedule rule that fires the aggregator."
  value       = aws_cloudwatch_event_rule.mttr_schedule.name
}

output "rca_lambda_log_group_insights_url" {
  description = <<-EOT
    Deep-link into CloudWatch Logs Insights pre-scoped to the RCA Lambda
    log group. Grafana per-reason breakouts run queries against this group.
  EOT
  value = format(
    "https://%s.console.aws.amazon.com/cloudwatch/home?region=%s#logsV2:logs-insights$3FqueryDetail~(~end~0~start~-3600~timeType~'RELATIVE~unit~'seconds~editorString~'fields*20*40timestamp*2c*20reason*2c*20rcaSource*0a*7c*20filter*20*40message*20like*20*2fincident*2f*0a*7c*20stats*20count**28**29*20by*20reason~source~(~'%s))",
    var.region,
    var.region,
    replace(module.lambda_rca.log_group_name, "/", "*2f"),
  )
}
