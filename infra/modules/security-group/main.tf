# Security group for K3s nodes.
#
# Ingress model (module 1 baseline):
#   - Nothing from the internet. All API/SSH access happens via SSM
#     (which uses AWS backbone + IAM, not open ports).
#   - Intra-cluster traffic: allow ALL from same SG (flannel, node-to-node,
#     kubelet, coredns, service ClusterIPs).
#
# Egress: all (needed to pull K3s from get.k3s.io, container images, and
# reach the SSM endpoints).
#
# Later modules will add ingress rules as needed:
#   - Module 3 (crashy-app): 80/443 from world when Ingress lands
#   - Module 2 (agent join): 6443 stays intra-SG (agents already inside)

resource "aws_security_group" "k3s" {
  name        = "${var.project}-k3s"
  description = "K3s server + agent nodes"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project}-k3s-sg"
  }
}

# ---- Self-referencing rules: allow all traffic within the SG --------------
resource "aws_vpc_security_group_ingress_rule" "self_all" {
  security_group_id            = aws_security_group.k3s.id
  referenced_security_group_id = aws_security_group.k3s.id
  ip_protocol                  = "-1"
  description                  = "Allow all traffic from other K3s nodes"
}

# ---- Egress: all outbound -------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "all_out_v4" {
  security_group_id = aws_security_group.k3s.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "All outbound IPv4"
}

resource "aws_vpc_security_group_egress_rule" "all_out_v6" {
  security_group_id = aws_security_group.k3s.id
  cidr_ipv6         = "::/0"
  ip_protocol       = "-1"
  description       = "All outbound IPv6"
}
