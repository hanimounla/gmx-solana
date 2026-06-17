variable "name_prefix" { type = string }
variable "api_gateway_endpoint" { type = string }
variable "alb_dns_name" { type = string }
variable "acm_certificate_arn" { type = string; description = "Must be in us-east-1 for CloudFront" }
variable "domain_aliases" { type = list(string); default = [] }
variable "logs_bucket" { type = string }
