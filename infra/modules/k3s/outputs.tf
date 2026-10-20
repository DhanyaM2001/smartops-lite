output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.this.id
}

output "public_ip" {
  description = "Public IPv4 address (allocated because the subnet has map_public_ip_on_launch)."
  value       = aws_instance.this.public_ip
}

output "private_ip" {
  description = "Private IPv4 inside the VPC."
  value       = aws_instance.this.private_ip
}

output "public_dns" {
  description = "Public DNS name."
  value       = aws_instance.this.public_dns
}
