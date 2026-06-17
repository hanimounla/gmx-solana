###############################################################################
# Module: EKS
#
# Creates:
#   • EKS cluster with private API endpoint
#   • 3 managed node groups: system, keepers, api
#   • Core addons: CoreDNS, kube-proxy, VPC CNI, EBS CSI
#   • aws-auth ConfigMap entries for node group access
###############################################################################

###############################################################################
# EKS Cluster
###############################################################################

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = var.cluster_role_arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(var.private_eks_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true # Set to false after initial setup + bastion is ready
    public_access_cidrs     = var.api_server_allowed_cidrs
    security_group_ids      = [aws_security_group.cluster.id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [var.cluster_role_arn]

  tags = {
    Name = var.cluster_name
  }
}

###############################################################################
# Cluster Security Group
###############################################################################

resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS cluster security group"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes-sg"
  description = "EKS nodes security group"
  vpc_id      = var.vpc_id

  ingress {
    description = "Node to node communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description     = "Cluster API to nodes"
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster.id]
  }

  ingress {
    description     = "ALB health checks"
    from_port       = 8080
    to_port         = 9090
    protocol        = "tcp"
    security_groups = [var.alb_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-nodes-sg"
  }
}

###############################################################################
# CloudWatch Log Group for cluster logs
###############################################################################

resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
}

###############################################################################
# Node Group — system (cluster addons + controllers)
###############################################################################

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system"
  node_role_arn   = var.node_group_role_arn
  subnet_ids      = var.private_eks_subnet_ids

  instance_types = ["t3.medium"]
  capacity_type  = "ON_DEMAND"
  disk_size      = 50

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role = "system"
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = {
    Name = "${var.cluster_name}-system-node"
  }
}

###############################################################################
# Node Group — keepers (CPU-optimised for Rust keeper processes)
###############################################################################

resource "aws_eks_node_group" "keepers" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "keepers"
  node_role_arn   = var.node_group_role_arn
  subnet_ids      = var.private_eks_subnet_ids

  instance_types = var.keeper_instance_types
  capacity_type  = "ON_DEMAND" # Keepers must NOT be on spot — interruptions = missed liquidations
  disk_size      = 50

  scaling_config {
    desired_size = var.keeper_desired_size
    min_size     = var.keeper_min_size
    max_size     = var.keeper_max_size
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role = "keepers"
  }

  tags = {
    Name = "${var.cluster_name}-keeper-node"
  }
}

###############################################################################
# Node Group — api (indexer, WS gateway — can tolerate spot interruptions)
###############################################################################

resource "aws_eks_node_group" "api" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "api"
  node_role_arn   = var.node_group_role_arn
  subnet_ids      = var.private_eks_subnet_ids

  instance_types = ["t3.large", "t3a.large"]
  capacity_type  = "SPOT"
  disk_size      = 50

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 8
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    role = "api"
  }

  tags = {
    Name = "${var.cluster_name}-api-node"
  }
}

###############################################################################
# EKS Add-ons
###############################################################################

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
}
