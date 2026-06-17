output "cloudfront_domain" {
  description = "CloudFront distribution domain — point your DNS CNAME here"
  value       = module.cloudfront.distribution_domain_name
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "rds_writer_endpoint" {
  value     = module.rds.cluster_endpoint
  sensitive = true
}

output "rds_reader_endpoint" {
  value     = module.rds.reader_endpoint
  sensitive = true
}

output "redis_primary_endpoint" {
  value     = module.elasticache.primary_endpoint
  sensitive = true
}

output "api_gateway_endpoint" {
  value = module.api_gateway.api_endpoint
}

output "ecr_repository_urls" {
  description = "Push Docker images to these ECR URLs"
  value       = module.ecr.repository_urls
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl"
  value       = "aws eks update-kubeconfig --region us-east-1 --name ${module.eks.cluster_name}"
}
