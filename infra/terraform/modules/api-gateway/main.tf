###############################################################################
# Module: API Gateway (HTTP API)
#
# Creates:
#   • HTTP API Gateway v2 with Lambda integrations
#   • Per-route throttling (burst: 10k, steady: 5k req/s)
#   • Custom domain + stage
#   • CORS policy
#   • CloudWatch access logging
###############################################################################

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.name_prefix}-api"
  protocol_type = "HTTP"
  description   = "GMSOL public read API"

  cors_configuration {
    allow_headers = ["content-type", "authorization"]
    allow_methods = ["GET", "OPTIONS"]
    allow_origins = var.cors_allowed_origins
    max_age       = 86400
  }

  tags = {
    Name = "${var.name_prefix}-api"
  }
}

###############################################################################
# Stage with access logging + throttling
###############################################################################

resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/${var.name_prefix}"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "main" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit   = 10000
    throttling_rate_limit    = 5000
    detailed_metrics_enabled = true
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
  }
}

###############################################################################
# Lambda Integrations + Routes
###############################################################################

locals {
  routes = {
    "GET /markets"                 = "markets"
    "GET /markets/{token}"         = "markets"
    "GET /positions/{wallet}"      = "positions"
    "GET /orders/{wallet}"         = "orders"
    "GET /competition/leaderboard" = "leaderboard"
    "GET /prices"                  = "prices"
    "GET /prices/{token}"          = "prices"
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  for_each = toset(values(local.routes))

  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.lambda_invoke_arns[each.key]
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_route" "api" {
  for_each = local.routes

  api_id    = aws_apigatewayv2_api.main.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.lambda[each.value].id}"
}

###############################################################################
# Lambda permissions for API Gateway to invoke each function
###############################################################################

resource "aws_lambda_permission" "api_gateway" {
  for_each = toset(values(local.routes))

  statement_id  = "AllowAPIGatewayInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = var.lambda_function_names[each.key]
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
