variable "name_prefix" { type = string }
variable "environment" { type = string }
variable "rds_cluster_identifier" { type = string }
variable "redis_replication_group_id" { type = string }
variable "pagerduty_endpoint" { type = string; default = "" }
variable "slack_webhook_url" { type = string; default = "" }
