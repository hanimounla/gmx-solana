###############################################################################
# Module: RDS (Aurora PostgreSQL)
#
# Creates:
#   • Aurora PostgreSQL cluster (Multi-AZ, Serverless v2)
#   • Writer + Reader instances
#   • Subnet group in private data subnets
#   • Security group (access only from EKS nodes + Lambda)
#   • Enhanced monitoring + Performance Insights
###############################################################################

###############################################################################
# Security Group
###############################################################################

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "Allow PostgreSQL access from EKS nodes and Lambda"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  ingress {
    description     = "PostgreSQL from Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.lambda_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-rds-sg"
  }
}

###############################################################################
# Subnet Group
###############################################################################

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-rds-subnet-group"
  subnet_ids = var.private_data_subnet_ids

  tags = {
    Name = "${var.name_prefix}-rds-subnet-group"
  }
}

###############################################################################
# Parameter Group
###############################################################################

resource "aws_rds_cluster_parameter_group" "main" {
  name   = "${var.name_prefix}-aurora-pg17"
  family = "aurora-postgresql17"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_duration"
    value = "1"
  }

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
  }

  parameter {
    name         = "max_connections"
    value        = "500"
    apply_method = "pending-reboot"
  }
}

###############################################################################
# IAM role for Enhanced Monitoring
###############################################################################

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.name_prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

###############################################################################
# Aurora Cluster (Serverless v2 for cost-efficient prod scaling)
###############################################################################

resource "aws_rds_cluster" "main" {
  cluster_identifier = "${var.name_prefix}-aurora-pg"
  engine             = "aurora-postgresql"
  engine_version     = "17.4"
  engine_mode        = "provisioned"

  database_name   = var.database_name
  master_username = var.master_username
  master_password = var.master_password

  db_subnet_group_name            = aws_db_subnet_group.main.name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.main.name
  vpc_security_group_ids          = [aws_security_group.rds.id]

  storage_encrypted = true

  # Serverless v2 scaling config
  serverlessv2_scaling_configuration {
    min_capacity = var.serverless_min_capacity
    max_capacity = var.serverless_max_capacity
  }

  backup_retention_period      = var.backup_retention_days
  preferred_backup_window      = "03:00-04:00"
  preferred_maintenance_window = "sun:04:00-sun:05:00"

  enabled_cloudwatch_logs_exports = ["postgresql"]

  deletion_protection = var.deletion_protection
  skip_final_snapshot = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.name_prefix}-final-snapshot" : null

  apply_immediately = false

  tags = {
    Name = "${var.name_prefix}-aurora-pg"
  }
}

###############################################################################
# Aurora Cluster Instances
###############################################################################

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${var.name_prefix}-aurora-writer"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  db_subnet_group_name = aws_db_subnet_group.main.name

  monitoring_role_arn = aws_iam_role.rds_monitoring.arn
  monitoring_interval = 30

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  auto_minor_version_upgrade = true

  tags = {
    Name = "${var.name_prefix}-aurora-writer"
  }
}

resource "aws_rds_cluster_instance" "reader" {
  identifier         = "${var.name_prefix}-aurora-reader"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.main.engine
  engine_version     = aws_rds_cluster.main.engine_version

  db_subnet_group_name = aws_db_subnet_group.main.name

  monitoring_role_arn = aws_iam_role.rds_monitoring.arn
  monitoring_interval = 30

  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  tags = {
    Name = "${var.name_prefix}-aurora-reader"
  }
}
