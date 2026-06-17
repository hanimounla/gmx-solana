output "function_arns" {
  description = "Map of function name → ARN"
  value       = { for k, v in aws_lambda_function.api : k => v.arn }
}

output "function_names" {
  value = { for k, v in aws_lambda_function.api : k => v.function_name }
}

output "lambda_security_group_id" {
  value = aws_security_group.lambda.id
}

output "invoke_arns" {
  description = "Map of function name → invoke ARN (for API Gateway integration)"
  value       = { for k, v in aws_lambda_function.api : k => v.invoke_arn }
}
