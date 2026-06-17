variable "name_prefix" {
  description = "Prefix for all IAM resource names"
  type        = string
}

variable "eks_oidc_issuer_url" {
  description = "OIDC issuer URL of the EKS cluster (for IRSA)"
  type        = string
}

variable "eks_oidc_thumbprint" {
  description = "TLS thumbprint for the OIDC provider"
  type        = string
  default     = "9e99a48a9960b14926bb7f3b02e22da2b0ab7280"
}
