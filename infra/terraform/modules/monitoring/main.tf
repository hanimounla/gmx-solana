###############################################################################
# Module: Monitoring
#
# Creates:
#   • CloudWatch alarms for all critical keeper metrics
#   • SNS topics (pagerduty + slack)
#   • CloudWatch Dashboard: "GMSOL Keeper Health"
#   • Log metric filters for error patterns
###############################################################################

###############################################################################
# SNS Topics
###############################################################################

resource "aws_sns_topic" "critical" {
  name = "${var.name_prefix}-alerts-critical"
}

resource "aws_sns_topic" "warning" {
  name = "${var.name_prefix}-alerts-warning"
}

# Connect SNS → PagerDuty (HTTPS subscription — endpoint set via console or separate automation)
resource "aws_sns_topic_subscription" "pagerduty" {
  count     = var.pagerduty_endpoint != "" ? 1 : 0
  topic_arn = aws_sns_topic.critical.arn
  protocol  = "https"
  endpoint  = var.pagerduty_endpoint
}

resource "aws_sns_topic_subscription" "slack" {
  count     = var.slack_webhook_url != "" ? 1 : 0
  topic_arn = aws_sns_topic.warning.arn
  protocol  = "https"
  endpoint  = var.slack_webhook_url
}

###############################################################################
# CloudWatch Log Groups
###############################################################################

resource "aws_cloudwatch_log_group" "keepers" {
  for_each          = toset(["keeper-order", "keeper-liquidator", "keeper-adl", "keeper-glv", "price-cache-daemon", "indexer", "ws-gateway"])
  name              = "/gmsol/${var.environment}/${each.key}"
  retention_in_days = 30
}

###############################################################################
# Metric Filters — Error rates from keeper logs
###############################################################################

resource "aws_cloudwatch_log_metric_filter" "keeper_errors" {
  for_each = toset(["keeper-order", "keeper-liquidator", "keeper-adl", "keeper-glv"])

  name           = "${var.name_prefix}-${each.key}-errors"
  pattern        = "[timestamp, level=\"ERROR\", ...]"
  log_group_name = aws_cloudwatch_log_group.keepers[each.key].name

  metric_transformation {
    name      = "${each.key}-error-count"
    namespace = "gmsol/keeper"
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "price_cache_stale" {
  name           = "${var.name_prefix}-price-cache-stale"
  pattern        = "PRICE_STALE"
  log_group_name = aws_cloudwatch_log_group.keepers["price-cache-daemon"].name

  metric_transformation {
    name      = "price-cache-stale-count"
    namespace = "gmsol/keeper"
    value     = "1"
    unit      = "Count"
  }
}

###############################################################################
# CRITICAL Alarms
###############################################################################

# Keeper down (no successful execution in 5 min)
resource "aws_cloudwatch_metric_alarm" "keeper_order_down" {
  alarm_name          = "${var.name_prefix}-keeper-order-DOWN"
  alarm_description   = "CRITICAL: Order keeper has not successfully executed an action in 5 minutes"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "orders-executed-total"
  namespace           = "gmsol/keeper"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
}

resource "aws_cloudwatch_metric_alarm" "keeper_liquidator_down" {
  alarm_name          = "${var.name_prefix}-keeper-liquidator-DOWN"
  alarm_description   = "CRITICAL: Liquidator keeper has not run a health check cycle in 5 minutes"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "liquidation-cycles-total"
  namespace           = "gmsol/keeper"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.warning.arn]
}

# Price cache stale — most critical issue (blocks all keeper execution)
resource "aws_cloudwatch_metric_alarm" "price_cache_stale" {
  alarm_name          = "${var.name_prefix}-PRICE-CACHE-STALE"
  alarm_description   = "CRITICAL: Oracle price cache is stale — keepers cannot execute orders"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "price-cache-stale-count"
  namespace           = "gmsol/keeper"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.critical.arn]
}

# High pending orders — potential bottleneck
resource "aws_cloudwatch_metric_alarm" "high_pending_orders" {
  alarm_name          = "${var.name_prefix}-HIGH-PENDING-ORDERS"
  alarm_description   = "WARNING: More than 50 orders have been pending for over 2 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "pending-orders-count"
  namespace           = "gmsol/keeper"
  period              = 120
  statistic           = "Maximum"
  threshold           = 50
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.warning.arn]
}

###############################################################################
# WARNING Alarms — Infrastructure
###############################################################################

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name_prefix}-rds-high-cpu"
  alarm_description   = "WARNING: Aurora CPU above 80% for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBClusterIdentifier = var.rds_cluster_identifier
  }

  alarm_actions = [aws_sns_topic.warning.arn]
}

resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  alarm_name          = "${var.name_prefix}-redis-high-memory"
  alarm_description   = "WARNING: Redis memory usage above 80%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationGroupId = var.redis_replication_group_id
  }

  alarm_actions = [aws_sns_topic.warning.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_error_rate" {
  alarm_name          = "${var.name_prefix}-lambda-error-rate"
  alarm_description   = "WARNING: Lambda API error rate above 1%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 100 # Adjust based on expected traffic
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.warning.arn]
}

###############################################################################
# CloudWatch Dashboard
###############################################################################

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-keeper-health"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "# GMSOL Keeper Health Dashboard — ${var.environment}"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "Orders Executed (per minute)"
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
          metrics = [
            ["gmsol/keeper", "orders-executed-total"],
            ["gmsol/keeper", "orders-failed-total"]
          ]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "Liquidations Executed"
          period = 60
          stat   = "Sum"
          view   = "timeSeries"
          metrics = [["gmsol/keeper", "liquidations-executed-total"]]
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 1
        width  = 8
        height = 6
        properties = {
          title  = "Pending Orders Count"
          period = 60
          stat   = "Maximum"
          view   = "timeSeries"
          metrics = [["gmsol/keeper", "pending-orders-count"]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 8
        height = 6
        properties = {
          title  = "TX Confirmation Latency (ms)"
          period = 60
          stat   = "p95"
          view   = "timeSeries"
          metrics = [["gmsol/keeper", "tx-confirmation-latency-ms"]]
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 7
        width  = 8
        height = 6
        properties = {
          title  = "Price Cache Staleness (ms)"
          period = 60
          stat   = "Maximum"
          view   = "timeSeries"
          metrics = [["gmsol/keeper", "price-cache-staleness-ms"]]
        }
      },
      {
        type   = "alarm"
        x      = 16
        y      = 7
        width  = 8
        height = 6
        properties = {
          title  = "Active Alarms"
          alarms = [
            aws_cloudwatch_metric_alarm.keeper_order_down.arn,
            aws_cloudwatch_metric_alarm.keeper_liquidator_down.arn,
            aws_cloudwatch_metric_alarm.price_cache_stale.arn,
            aws_cloudwatch_metric_alarm.high_pending_orders.arn,
          ]
        }
      }
    ]
  })
}
