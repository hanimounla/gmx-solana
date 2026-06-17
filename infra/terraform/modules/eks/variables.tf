variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs (for cluster endpoint)"
  type        = list(string)
}

variable "private_eks_subnet_ids" {
  description = "Private subnet IDs for EKS node groups"
  type        = list(string)
}

variable "cluster_role_arn" {
  description = "IAM role ARN for the EKS cluster"
  type        = string
}

variable "node_group_role_arn" {
  description = "IAM role ARN for EKS node groups"
  type        = string
}

variable "alb_security_group_id" {
  description = "Security group ID of the ALB (for health check ingress rules)"
  type        = string
}

variable "api_server_allowed_cidrs" {
  description = "CIDR blocks allowed to reach the EKS API server (restrict to your office/VPN IPs in prod)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "keeper_instance_types" {
  description = "Instance types for keeper node group"
  type        = list(string)
  default     = ["c6i.2xlarge"]
}

variable "keeper_desired_size" {
  type    = number
  default = 2
}

variable "keeper_min_size" {
  type    = number
  default = 2
}

variable "keeper_max_size" {
  type    = number
  default = 6
}
