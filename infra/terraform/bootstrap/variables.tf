variable "aws_region" {
  description = "AWS region for the state infrastructure"
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS account ID — used to generate a globally unique S3 bucket name"
  type        = string
}
