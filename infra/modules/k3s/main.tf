# A single K3s node — either 'server' (first, control-plane) or 'agent'
# (worker; used by Module 2 onwards).
#
# The heavy lifting is in cloud-init.yaml.tftpl:
#   - installs K3s (server or agent depending on var.role)
#   - waits for readiness
#   - on server role: rewrites the kubeconfig to use the public IP as the
#     server endpoint, then uploads it to SSM as a SecureString parameter
#     (so the developer laptop can pull it via `aws ssm get-parameter`)

data "cloudinit_config" "user_data" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    filename     = "01-k3s.yaml"
    content = templatefile("${path.module}/cloud-init.yaml.tftpl", {
      role                 = var.role
      env                  = var.env
      ssm_kubeconfig_param = var.ssm_kubeconfig_param
      region               = var.region
      server_instance_id   = var.server_instance_id
    })
  }
}

# While a replacement server's ID is still unknown at plan time, so is the
# agent's user_data diff, and user_data_replace_on_change can't fire on its
# own. Replacing this whenever the ID changes forces the agent onto a fresh
# instance too (a no-op for the server, whose value is always "").
resource "terraform_data" "server_ref" {
  triggers_replace = var.server_instance_id
}

resource "aws_instance" "this" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = var.security_group_ids
  iam_instance_profile   = var.instance_profile
  user_data_base64       = data.cloudinit_config.user_data.rendered

  # cloud-init runs only on first boot, so an in-place user_data update
  # would never take effect — replace the node instead.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 required (hardening)
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2 # kube-proxy inside pods may need 2 hops
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    delete_on_termination = true
    encrypted             = true
    tags = {
      Name = "${var.project}-k3s-${var.role}-root"
    }
  }

  # Instance store for pod ephemeral storage isn't needed on t3.micro.

  tags = {
    Name = "${var.project}-k3s-${var.role}"
    role = var.role
  }

  lifecycle {
    ignore_changes = [
      # AMI updates should be an explicit operation, not a plan-time drift
      ami,
    ]
    replace_triggered_by = [terraform_data.server_ref]
  }
}
