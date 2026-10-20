variable "project" {
  description = "Project prefix."
  type        = string
}

variable "env" {
  description = "Environment name (dev/staging/prod) — used for SSM param path scoping."
  type        = string
}

variable "ssm_kubeconfig_param_name" {
  description = "SSM parameter path where the K3s server uploads its kubeconfig."
  type        = string
}

variable "attach_ecr_read_only" {
  description = <<-EOT
    Attach the AWS-managed AmazonEC2ContainerRegistryReadOnly policy to
    the node role. Enable from Module 3 onwards when K3s starts pulling
    private images from ECR. Kept behind a toggle so Modules 1-2 don't
    grant unused permissions.
  EOT
  type        = bool
  default     = false
}

variable "attach_controller_policy" {
  description = <<-EOT
    Attach the smartops-controller inline policy to the node role
    (grants events:PutEvents on the SmartOps EventBridge bus).
    Enable from Module 4 onwards when the in-cluster controller pod
    starts publishing incidents to EventBridge. Uses NODE IAM (pod
    inherits creds from EC2 IMDS) rather than IRSA — chosen for K3s
    simplicity; see docs/modules/04-controller.md for the trade-off.
  EOT
  type        = bool
  default     = false
}

variable "event_bus_arn" {
  description = <<-EOT
    ARN of the EventBridge custom bus the controller writes to. Only
    used when attach_controller_policy=true; safe to leave "" otherwise.
  EOT
  type        = string
  default     = ""
}
