output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs (for ALB, NAT GW)"
  value       = aws_subnet.public[*].id
}

output "private_eks_subnet_ids" {
  description = "Private subnet IDs for EKS nodes"
  value       = aws_subnet.private_eks[*].id
}

output "private_data_subnet_ids" {
  description = "Private subnet IDs for RDS and Redis"
  value       = aws_subnet.private_data[*].id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}
