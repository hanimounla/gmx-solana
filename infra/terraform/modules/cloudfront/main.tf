###############################################################################
# Module: CloudFront + WAF
#
# Creates:
#   • CloudFront distribution with two origins:
#     - API Gateway (REST/Lambda)
#     - ALB (WebSocket + static assets)
#   • WAF WebACL with AWS Managed Rules + rate limiting
#   • Cache policies: 60s for market data, no-cache for position/order data
###############################################################################

###############################################################################
# WAF WebACL (must be in us-east-1 for CloudFront)
###############################################################################

resource "aws_wafv2_web_acl" "cloudfront" {
  name  = "${var.name_prefix}-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # 1. AWS Core Rule Set
  rule {
    name     = "AWSManagedRulesCoreRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCoreRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCoreRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # 2. Known Bad Inputs
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # 3. IP Rate Limiting — 1000 req / 5 min per IP
  rule {
    name     = "RateLimitPerIP"
    priority = 10

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
        evaluation_window_sec = 300
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIP"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.name_prefix}-waf"
  }
}

###############################################################################
# Cache Policies
###############################################################################

resource "aws_cloudfront_cache_policy" "market_data" {
  name        = "${var.name_prefix}-market-data-60s"
  comment     = "Cache market and price data for 60 seconds"
  default_ttl = 60
  max_ttl     = 120
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

resource "aws_cloudfront_cache_policy" "no_cache" {
  name        = "${var.name_prefix}-no-cache"
  comment     = "No cache — for per-wallet position/order data"
  default_ttl = 0
  max_ttl     = 0
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "all" }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

###############################################################################
# CloudFront Distribution
###############################################################################

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "GMSOL CDN — API + WebSocket"
  price_class         = "PriceClass_100" # US + EU only for lower latency/cost
  web_acl_id          = aws_wafv2_web_acl.cloudfront.arn
  aliases             = var.domain_aliases
  http_version        = "http2and3"

  ###################################
  # Origin 1: API Gateway (REST API)
  ###################################

  origin {
    origin_id   = "api-gateway"
    domain_name = replace(var.api_gateway_endpoint, "https://", "")

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  ###################################
  # Origin 2: ALB (WebSocket gateway)
  ###################################

  origin {
    origin_id   = "alb-ws"
    domain_name = var.alb_dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  ###################################
  # Behaviour: /api/* → API Gateway
  ###################################

  ordered_cache_behavior {
    path_pattern     = "/api/markets*"
    target_origin_id = "api-gateway"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]

    cache_policy_id = aws_cloudfront_cache_policy.market_data.id

    viewer_protocol_policy = "https-only"
    compress               = true
  }

  ordered_cache_behavior {
    path_pattern     = "/api/prices*"
    target_origin_id = "api-gateway"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]

    cache_policy_id = aws_cloudfront_cache_policy.market_data.id

    viewer_protocol_policy = "https-only"
    compress               = true
  }

  ordered_cache_behavior {
    path_pattern     = "/api/*"
    target_origin_id = "api-gateway"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]

    cache_policy_id = aws_cloudfront_cache_policy.no_cache.id

    viewer_protocol_policy = "https-only"
    compress               = true
  }

  ###################################
  # Behaviour: /ws/* → ALB (WebSocket)
  ###################################

  ordered_cache_behavior {
    path_pattern     = "/ws*"
    target_origin_id = "alb-ws"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]

    cache_policy_id = aws_cloudfront_cache_policy.no_cache.id

    viewer_protocol_policy = "https-only"
    compress               = false # Don't compress WebSocket
  }

  ###################################
  # Default: ALB
  ###################################

  default_cache_behavior {
    target_origin_id = "alb-ws"
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]

    cache_policy_id = aws_cloudfront_cache_policy.no_cache.id

    viewer_protocol_policy = "redirect-to-https"
    compress               = true
  }

  ###################################
  # TLS
  ###################################

  viewer_certificate {
    acm_certificate_arn      = var.acm_certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  ###################################
  # Logging
  ###################################

  logging_config {
    include_cookies = false
    bucket          = "${var.logs_bucket}.s3.amazonaws.com"
    prefix          = "cloudfront/"
  }

  tags = {
    Name = "${var.name_prefix}-cdn"
  }
}
