output "critical_sns_topic_arn" { value = aws_sns_topic.critical.arn }
output "warning_sns_topic_arn" { value = aws_sns_topic.warning.arn }
output "dashboard_name" { value = aws_cloudwatch_dashboard.main.dashboard_name }
