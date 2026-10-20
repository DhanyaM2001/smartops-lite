output "vpc_id" {
  description = "The ID of the created VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (one per AZ, in order)."
  value       = aws_subnet.public[*].id
}

output "public_subnet_azs" {
  description = "Availability zones matching the public subnets (in the same order)."
  value       = aws_subnet.public[*].availability_zone
}
