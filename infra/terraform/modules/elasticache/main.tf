###############################################################################
# Module: ElastiCache (Redis)
#
# Creates:
#   • Redis 7.x replication group (Multi-AZ with automatic failover)
#   • Subnet group in private data subnets
#   • Security group (access only from EKS nodes)
#   • TLS in-transit + at-rest encryption
###############################################################################

###############################################################################
# Security Group
###############################################################################

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis-sg"
  description = "Allow Redis access from EKS nodes only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-redis-sg"
  }
}

###############################################################################
# Subnet Group
###############################################################################

resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.name_prefix}-redis-subnet-group"
  subnet_ids = var.private_data_subnet_ids

  tags = {
    Name = "${var.name_prefix}-redis-subnet-group"
  }
}

###############################################################################
# Parameter Group (Redis 7.x — optimised for price cache workload)
###############################################################################

resource "aws_elasticache_parameter_group" "main" {
  name   = "${var.name_prefix}-redis7"
  family = "redis7"

  # Evict LRU keys when memory is full (price data is ephemeral)
  parameter {
    name  = "maxmemory-policy"
    value = "volatile-lru"
  }

  parameter {
    name  = "lazyfree-lazy-eviction"
    value = "yes"
  }

  parameter {
    name  = "lazyfree-lazy-expire"
    value = "yes"
  }

  # Notify keyspace events for expired keys (useful for monitoring stale prices)
  parameter {
    name  = "notify-keyspace-events"
    value = "Ex"
  }
}

###############################################################################
# Redis Replication Group
###############################################################################

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.name_prefix}-redis"
  description          = "GMSOL price cache and distributed keeper locks"

  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.node_type
  num_cache_clusters   = 2 # Primary + one replica (Multi-AZ)
  parameter_group_name = aws_elasticache_parameter_group.main.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]

  automatic_failover_enabled = true
  multi_az_enabled           = true

  # TLS
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  # Auth token for TLS connections
  auth_token = var.auth_token

  # Maintenance + backups
  maintenance_window       = "sun:05:00-sun:06:00"
  snapshot_window          = "04:00-05:00"
  snapshot_retention_limit = 3

  apply_immediately = false

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_slow.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_engine.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "engine-log"
  }

  tags = {
    Name = "${var.name_prefix}-redis"
  }
}

###############################################################################
# CloudWatch Log Groups for Redis logs
###############################################################################

resource "aws_cloudwatch_log_group" "redis_slow" {
  name              = "/aws/elasticache/${var.name_prefix}/slow-log"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "redis_engine" {
  name              = "/aws/elasticache/${var.name_prefix}/engine-log"
  retention_in_days = 7
}
