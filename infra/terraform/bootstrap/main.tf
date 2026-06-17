###############################################################################
# BOOTSTRAP — Run ONCE before any other Terraform apply
#
# Creates:
#   • S3 bucket for Terraform remote state (versioned, encrypted)
#   • DynamoDB table for state locking
#
# Usage:
#   cd infra/terraform/bootstrap
#   terraform init
#   terraform apply -var="aws_account_id=$(aws sts get-caller-identity --query Account --output text)"
###############################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "gmsol"
      ManagedBy   = "terraform"
      Environment = "bootstrap"
    }
  }
}

###############################################################################
# S3 — Terraform State Bucket
###############################################################################

resource "aws_s3_bucket" "terraform_state" {
  bucket = "gmsol-terraform-state-${var.aws_account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# DynamoDB — State Lock Table
###############################################################################

resource "aws_dynamodb_table" "terraform_lock" {
  name         = "gmsol-terraform-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  lifecycle {
    prevent_destroy = true
  }
}

###############################################################################
# Outputs
###############################################################################

output "state_bucket_name" {
  description = "Name of the Terraform state S3 bucket"
  value       = aws_s3_bucket.terraform_state.bucket
}

output "lock_table_name" {
  description = "Name of the DynamoDB state lock table"
  value       = aws_dynamodb_table.terraform_lock.name
}

output "backend_config_snippet" {
  description = "Paste this backend block into your environment main.tf"
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.terraform_state.bucket}"
        key            = "<env>/terraform.tfstate"
        region         = "${var.aws_region}"
        dynamodb_table = "${aws_dynamodb_table.terraform_lock.name}"
        encrypt        = true
      }
    }
  EOT
}
