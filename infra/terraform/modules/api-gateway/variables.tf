variable "name_prefix" { type = string }
variable "lambda_invoke_arns" { type = map(string) }
variable "lambda_function_names" { type = map(string) }
variable "cors_allowed_origins" { type = list(string); default = ["*"] }
