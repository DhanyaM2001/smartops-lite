# IAM role + instance profile attached to every K3s node.
#
# Grants:
#   - AmazonSSMManagedInstanceCore (AWS-managed) — Session Manager access +
#       fleet management + patching. This is what lets us tunnel into the
#       cluster without opening SSH.
#   - Inline: ssm:PutParameter (limited) — cloud-init uploads the kubeconfig
#       to /smartops/<env>/kubeconfig as SecureString on first boot.
#   - Inline: ssm:GetParameter on /smartops/* — for the K3s controller later
#       (Module 4) to read Slack + Groq secrets. Broad-enough now, will be
#       tightened via IRSA in Module 4.
#
# Later modules will layer more inline policies on this role:
#   - Module 5: events:PutEvents to EventBridge bus
#   - Module 3: ecr:GetAuthorizationToken + ecr:BatchGetImage (for pulls)

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_iam_role" "node" {
  name = "${var.project}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project}-node-role"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ---- ECR pull permission (Module 3) --------------------------------------
# Toggled by var.attach_ecr_read_only so Modules 1-2 keep a minimal role.
# The AWS-managed policy grants: ecr:GetAuthorizationToken, ecr:BatchGetImage,
# ecr:BatchCheckLayerAvailability, ecr:GetDownloadUrlForLayer — everything
# containerd needs to pull a private image.
resource "aws_iam_role_policy_attachment" "ecr_read_only" {
  count      = var.attach_ecr_read_only ? 1 : 0
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ---- Controller policy (Module 4) ----------------------------------------
# Grants events:PutEvents on the SmartOps custom EventBridge bus ONLY.
# The controller pod inherits these creds from the EC2 IMDS credential
# chain — no per-pod IAM role today (see ADR in docs/modules/04-controller.md).
#
# Scoped as tightly as we can:
#   - Only the ONE bus ARN passed in via var.event_bus_arn
#   - No wildcards on the action
#   - Kept off (var.attach_controller_policy=false) until Module 4 applies
resource "aws_iam_role_policy" "controller" {
  count = var.attach_controller_policy ? 1 : 0
  name  = "${var.project}-controller-inline"
  role  = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PublishIncidentsToEventBridge"
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = var.event_bus_arn
      },
    ]
  })
}

# ---- Inline policy: upload kubeconfig + read shared secrets --------------
resource "aws_iam_role_policy" "smartops" {
  name = "${var.project}-node-inline"
  role = aws_iam_role.node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Cloud-init on the K3s server writes FOUR SSM parameters on first
        # boot (see infra/modules/k3s/cloud-init.yaml.tftpl):
        #   1. <ssm_kubeconfig_param_name>                — kubeconfig (SecureString)
        #   2. /smartops/<env>/k3s_join_token             — agent join secret (SecureString)
        #   3. /smartops/<env>/k3s_server_url             — agent bootstrap URL (String)
        #   4. /smartops/<env>/k3s_server_instance_id     — which server wrote 1-3 (String)
        # All four must be writable or the agent never joins (server exits
        # with AccessDenied on a put, agent times out waiting for the stamp).
        # Kept scoped to these specific ARNs — never broader.
        Sid    = "UploadKubeconfigAndK3sJoinParams"
        Effect = "Allow"
        Action = [
          "ssm:PutParameter",
          "ssm:AddTagsToResource",
        ]
        Resource = [
          format(
            "arn:aws:ssm:%s:%s:parameter%s",
            data.aws_region.current.name,
            data.aws_caller_identity.current.account_id,
            var.ssm_kubeconfig_param_name,
          ),
          format(
            "arn:aws:ssm:%s:%s:parameter/smartops/%s/k3s_join_token",
            data.aws_region.current.name,
            data.aws_caller_identity.current.account_id,
            var.env,
          ),
          format(
            "arn:aws:ssm:%s:%s:parameter/smartops/%s/k3s_server_url",
            data.aws_region.current.name,
            data.aws_caller_identity.current.account_id,
            var.env,
          ),
          format(
            "arn:aws:ssm:%s:%s:parameter/smartops/%s/k3s_server_instance_id",
            data.aws_region.current.name,
            data.aws_caller_identity.current.account_id,
            var.env,
          ),
        ]
      },
      {
        Sid    = "ReadSharedSecrets"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = format(
          "arn:aws:ssm:%s:%s:parameter/smartops/%s/*",
          data.aws_region.current.name,
          data.aws_caller_identity.current.account_id,
          var.env,
        )
      },
      {
        Sid      = "KmsDecryptForSecureString"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = format("ssm.%s.amazonaws.com", data.aws_region.current.name)
          }
        }
      },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = "${var.project}-node-profile"
  role = aws_iam_role.node.name
}
