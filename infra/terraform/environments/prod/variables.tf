variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "api_server_allowed_cidrs" {
  description = "CIDRs allowed to reach EKS API server (restrict to VPN/office IPs in prod)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "db_master_password" {
  description = "Aurora master password — supply via TF_VAR_db_master_password env var, never in tfvars"
  type        = string
  sensitive   = true
}

variable "redis_auth_token" {
  description = "Redis auth token — supply via TF_VAR_redis_auth_token env var, never in tfvars"
  type        = string
  sensitive   = true
}

variable "acm_certificate_arn" {
  description = "ACM certificate ARN (same region as ALB)"
  type        = string
}

variable "acm_certificate_arn_us_east_1" {
  description = "ACM certificate ARN in us-east-1 (required for CloudFront)"
  type        = string
}

variable "domain_aliases" {
  description = "Custom domain names for CloudFront (e.g. ['api.gmsol.io'])"
  type        = list(string)
  default     = []
}

variable "cors_allowed_origins" {
  type    = list(string)
  default = ["https://app.gmsol.io"]
}

variable "pagerduty_endpoint" {
  type      = string
  sensitive = true
  default   = ""
}

variable "slack_webhook_url" {
  type      = string
  sensitive = true
  default   = ""
}
