###############################################################################
# Module: S3 Buckets
###############################################################################

data "aws_caller_identity" "current" {}

###############################################################################
# ALB Access Logs Bucket
###############################################################################

resource "aws_s3_bucket" "alb_logs" {
  bucket = "${var.name_prefix}-alb-logs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter { prefix = "" }

    expiration {
      days = 90
    }
  }
}

# ALB requires a bucket policy to write access logs
resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::127311923021:root" } # us-east-1 ELB account
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/alb/*"
    }]
  })
}

###############################################################################
# CloudFront / General Access Logs
###############################################################################

resource "aws_s3_bucket" "logs" {
  bucket = "${var.name_prefix}-logs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter { prefix = "" }

    expiration {
      days = 90
    }
  }
}

###############################################################################
# ALT (Address Lookup Tables) Configuration Bucket
###############################################################################

resource "aws_s3_bucket" "alts" {
  bucket = "${var.name_prefix}-alts-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "alts" {
  bucket = aws_s3_bucket.alts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alts" {
  bucket = aws_s3_bucket.alts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "alts" {
  bucket                  = aws_s3_bucket.alts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
