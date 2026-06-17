output "alb_logs_bucket" { value = aws_s3_bucket.alb_logs.bucket }
output "logs_bucket" { value = aws_s3_bucket.logs.bucket }
output "alts_bucket" { value = aws_s3_bucket.alts.bucket }
output "alts_bucket_arn" { value = aws_s3_bucket.alts.arn }
