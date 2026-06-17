variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "private_data_subnet_ids" { type = list(string) }
variable "eks_node_security_group_id" { type = string }
variable "lambda_security_group_id" { type = string }
variable "database_name" { type = string; default = "gmsol" }
variable "master_username" { type = string; default = "gmsol_admin" }
variable "master_password" { type = string; sensitive = true }
variable "backup_retention_days" { type = number; default = 7 }
variable "deletion_protection" { type = bool; default = true }
variable "serverless_min_capacity" { type = number; default = 0.5 }
variable "serverless_max_capacity" { type = number; default = 16 }
