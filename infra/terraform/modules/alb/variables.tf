variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "acm_certificate_arn" { type = string }
variable "access_logs_bucket" { type = string }
variable "enable_deletion_protection" { type = bool; default = true }
