output "k3s_sg_id" {
  description = "Security group ID applied to all K3s nodes."
  value       = aws_security_group.k3s.id
}
