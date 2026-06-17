variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "private_data_subnet_ids" { type = list(string) }
variable "eks_node_security_group_id" { type = string }
variable "node_type" { type = string; default = "cache.r6g.large" }
variable "auth_token" { type = string; sensitive = true }
