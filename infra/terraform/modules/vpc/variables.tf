variable "name_prefix" {
  description = "Prefix for all resource names (e.g. 'gmsol-prod')"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name — used to tag subnets for Kubernetes discovery"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to use (exactly 2 recommended for cost/HA balance)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}
