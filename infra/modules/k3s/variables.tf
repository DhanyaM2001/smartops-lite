variable "project" {
  description = "Project prefix used in resource names/tags."
  type        = string
}

variable "env" {
  description = "Environment name (dev/staging/prod). Used to scope SSM param paths written by cloud-init: /smartops/<env>/k3s_join_token, /smartops/<env>/k3s_server_url."
  type        = string
}

variable "role" {
  description = "K3s role — 'server' (control plane) or 'agent' (worker)."
  type        = string
  validation {
    condition     = contains(["server", "agent"], var.role)
    error_message = "role must be 'server' or 'agent'."
  }
}

variable "ami_id" {
  description = "AMI ID for the EC2 instance (Ubuntu 24.04 LTS amd64)."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
}

variable "root_volume_gb" {
  description = "Root EBS volume size in GB."
  type        = number
}

variable "subnet_id" {
  description = "Subnet ID where the instance is launched."
  type        = string
}

variable "security_group_ids" {
  description = "Security group IDs attached to the instance."
  type        = list(string)
}

variable "instance_profile" {
  description = "IAM instance profile name."
  type        = string
}

variable "ssm_kubeconfig_param" {
  description = "SSM parameter path where server role uploads the kubeconfig."
  type        = string
}

variable "region" {
  description = "AWS region — passed into cloud-init for `aws ssm put-parameter`."
  type        = string
}

variable "server_instance_id" {
  description = "Agent only: instance ID of the server to join. The agent waits until the server has stamped this ID into SSM, so it never joins with a previous server's token/URL. Leave empty for the server."
  type        = string
  default     = ""
}
