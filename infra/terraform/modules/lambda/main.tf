###############################################################################
# Module: Lambda (Read API)
#
# Creates Lambda functions for the public read-only API:
#   • fn-markets    — GET /markets, /markets/{token}
#   • fn-positions  — GET /positions/{wallet}
#   • fn-orders     — GET /orders/{wallet}
#   • fn-leaderboard — GET /competition/leaderboard
#   • fn-prices     — GET /prices (Redis-backed, ultra-low latency)
#
# All functions run inside the VPC for RDS/Redis access.
# Binaries are compiled with cargo-lambda (provided.al2023 runtime).
###############################################################################

###############################################################################
# Security Group for Lambda VPC functions
###############################################################################

resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda-sg"
  description = "Lambda functions — outbound to RDS + Redis"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-lambda-sg"
  }
}

###############################################################################
# Lambda placeholder zip (replaced by CI/CD push)
###############################################################################

data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "${path.module}/placeholder.zip"

  source {
    content  = "# placeholder — replaced by cargo-lambda build in CI"
    filename = "bootstrap"
  }
}

###############################################################################
# Lambda Functions
###############################################################################

locals {
  lambda_functions = {
    "markets"     = { description = "Returns market list and individual market data", timeout = 10 }
    "positions"   = { description = "Returns positions for a given wallet", timeout = 10 }
    "orders"      = { description = "Returns orders for a given wallet", timeout = 10 }
    "leaderboard" = { description = "Returns competition leaderboard", timeout = 15 }
    "prices"      = { description = "Returns current oracle prices from Redis cache", timeout = 5 }
  }
}

resource "aws_lambda_function" "api" {
  for_each = local.lambda_functions

  function_name = "${var.name_prefix}-fn-${each.key}"
  description   = each.value.description
  role          = var.lambda_exec_role_arn
  handler       = "bootstrap"
  runtime       = "provided.al2023"
  architectures = ["arm64"] # Graviton2 — cheaper + faster for Rust
  timeout       = each.value.timeout
  memory_size   = 512

  filename         = data.archive_file.placeholder.output_path
  source_code_hash = data.archive_file.placeholder.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      ENVIRONMENT             = var.environment
      DB_READER_HOST          = var.db_reader_endpoint
      DB_NAME                 = var.db_name
      DB_SECRET_ARN           = var.db_password_secret_arn
      REDIS_HOST              = var.redis_endpoint
      REDIS_PORT              = "6379"
      REDIS_TLS               = "true"
      REDIS_SECRET_ARN        = var.redis_auth_token_secret_arn
      SOLANA_RPC_SECRET_ARN   = var.rpc_api_key_secret_arn
      RUST_LOG                = "info"
    }
  }

  tracing_config {
    mode = "Active"
  }

  lifecycle {
    ignore_changes = [filename, source_code_hash] # CI/CD manages deployments
  }

  tags = {
    Name = "${var.name_prefix}-fn-${each.key}"
  }
}

###############################################################################
# CloudWatch Log Groups per function
###############################################################################

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = local.lambda_functions

  name              = "/aws/lambda/${var.name_prefix}-fn-${each.key}"
  retention_in_days = 14
}

###############################################################################
# Lambda Concurrency — prices endpoint can scale more aggressively
###############################################################################

resource "aws_lambda_function_event_invoke_config" "api" {
  for_each      = local.lambda_functions
  function_name = aws_lambda_function.api[each.key].function_name

  maximum_retry_attempts = 0 # API functions shouldn't retry on failure
}
