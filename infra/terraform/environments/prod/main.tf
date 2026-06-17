###############################################################################
# PRODUCTION Environment
#
# Wires all modules together for the production deployment.
# Usage:
#   cd infra/terraform/environments/prod
#   terraform init
#   terraform plan -var-file=terraform.tfvars
#   terraform apply -var-file=terraform.tfvars
###############################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }

  backend "s3" {
    bucket         = "gmsol-terraform-state-ACCOUNT_ID" # Replace with actual account ID after bootstrap
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "gmsol-terraform-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "gmsol"
      Environment = "prod"
      ManagedBy   = "terraform"
      Repository  = "github.com/gmsol-labs/gmx-solana"
    }
  }
}

# Kubernetes provider — configured after EKS cluster is created
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name]
  }
}

###############################################################################
# Locals
###############################################################################

locals {
  name_prefix  = "gmsol-prod"
  cluster_name = "gmsol-prod"
  environment  = "prod"
}

###############################################################################
# S3 Buckets (created first — needed by ALB and CloudFront)
###############################################################################

module "s3" {
  source      = "../../modules/s3"
  name_prefix = local.name_prefix
}

###############################################################################
# Secrets (created early — RDS password needed for RDS module)
###############################################################################

module "secrets" {
  source      = "../../modules/secrets"
  name_prefix = local.name_prefix
}

###############################################################################
# VPC
###############################################################################

module "vpc" {
  source = "../../modules/vpc"

  name_prefix        = local.name_prefix
  cluster_name       = local.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

###############################################################################
# IAM (partial — EKS OIDC requires cluster to exist first)
# IRSA roles are created after EKS outputs the OIDC issuer URL
###############################################################################

module "iam" {
  source = "../../modules/iam"

  name_prefix         = local.name_prefix
  eks_oidc_issuer_url = module.eks.cluster_oidc_issuer_url

  depends_on = [module.eks]
}

###############################################################################
# ECR
###############################################################################

module "ecr" {
  source      = "../../modules/ecr"
  name_prefix = local.name_prefix
}

###############################################################################
# ALB (needs Security Group ID before EKS — referenced in EKS node SG rules)
###############################################################################

module "alb" {
  source = "../../modules/alb"

  name_prefix                = local.name_prefix
  vpc_id                     = module.vpc.vpc_id
  public_subnet_ids          = module.vpc.public_subnet_ids
  acm_certificate_arn        = var.acm_certificate_arn
  access_logs_bucket         = module.s3.alb_logs_bucket
  enable_deletion_protection = true
}

###############################################################################
# EKS
###############################################################################

module "eks" {
  source = "../../modules/eks"

  cluster_name             = local.cluster_name
  kubernetes_version       = "1.31"
  vpc_id                   = module.vpc.vpc_id
  public_subnet_ids        = module.vpc.public_subnet_ids
  private_eks_subnet_ids   = module.vpc.private_eks_subnet_ids
  cluster_role_arn         = module.iam.eks_cluster_role_arn
  node_group_role_arn      = module.iam.eks_node_group_role_arn
  alb_security_group_id    = module.alb.alb_security_group_id
  api_server_allowed_cidrs = var.api_server_allowed_cidrs
  keeper_instance_types    = ["c6i.2xlarge"]
  keeper_desired_size      = 2
  keeper_min_size          = 2
  keeper_max_size          = 6

  depends_on = [module.iam, module.vpc]
}

###############################################################################
# RDS
###############################################################################

module "rds" {
  source = "../../modules/rds"

  name_prefix                = local.name_prefix
  vpc_id                     = module.vpc.vpc_id
  private_data_subnet_ids    = module.vpc.private_data_subnet_ids
  eks_node_security_group_id = module.eks.node_security_group_id
  lambda_security_group_id   = module.lambda.lambda_security_group_id
  master_password            = var.db_master_password
  deletion_protection        = true
  serverless_min_capacity    = 0.5
  serverless_max_capacity    = 32

  depends_on = [module.vpc, module.eks]
}

###############################################################################
# ElastiCache (Redis)
###############################################################################

module "elasticache" {
  source = "../../modules/elasticache"

  name_prefix                = local.name_prefix
  vpc_id                     = module.vpc.vpc_id
  private_data_subnet_ids    = module.vpc.private_data_subnet_ids
  eks_node_security_group_id = module.eks.node_security_group_id
  node_type                  = "cache.r6g.large"
  auth_token                 = var.redis_auth_token

  depends_on = [module.vpc, module.eks]
}

###############################################################################
# Lambda (Read API)
###############################################################################

module "lambda" {
  source = "../../modules/lambda"

  name_prefix                 = local.name_prefix
  environment                 = local.environment
  vpc_id                      = module.vpc.vpc_id
  private_subnet_ids          = module.vpc.private_eks_subnet_ids
  lambda_exec_role_arn        = module.iam.lambda_exec_role_arn
  db_reader_endpoint          = module.rds.reader_endpoint
  db_name                     = "gmsol"
  db_password_secret_arn      = module.secrets.db_password_arn
  redis_endpoint              = module.elasticache.primary_endpoint
  redis_auth_token_secret_arn = module.secrets.redis_auth_token_arn
  rpc_api_key_secret_arn      = module.secrets.rpc_helius_api_key_arn

  depends_on = [module.rds, module.elasticache, module.iam]
}

###############################################################################
# API Gateway
###############################################################################

module "api_gateway" {
  source = "../../modules/api-gateway"

  name_prefix           = local.name_prefix
  lambda_invoke_arns    = module.lambda.invoke_arns
  lambda_function_names = module.lambda.function_names
  cors_allowed_origins  = var.cors_allowed_origins

  depends_on = [module.lambda]
}

###############################################################################
# CloudFront + WAF
###############################################################################

module "cloudfront" {
  source = "../../modules/cloudfront"

  name_prefix          = local.name_prefix
  api_gateway_endpoint = module.api_gateway.api_endpoint
  alb_dns_name         = module.alb.alb_dns_name
  acm_certificate_arn  = var.acm_certificate_arn_us_east_1
  domain_aliases       = var.domain_aliases
  logs_bucket          = module.s3.logs_bucket

  depends_on = [module.api_gateway, module.alb]
}

###############################################################################
# Monitoring
###############################################################################

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix                = local.name_prefix
  environment                = local.environment
  rds_cluster_identifier     = module.rds.cluster_identifier
  redis_replication_group_id = "gmsol-prod-redis"
  pagerduty_endpoint         = var.pagerduty_endpoint
  slack_webhook_url          = var.slack_webhook_url

  depends_on = [module.rds, module.elasticache, module.eks]
}
