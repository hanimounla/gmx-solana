output "cluster_endpoint" {
  description = "Writer endpoint"
  value       = aws_rds_cluster.main.endpoint
}

output "reader_endpoint" {
  description = "Reader endpoint (for read-only Lambda queries)"
  value       = aws_rds_cluster.main.reader_endpoint
}

output "cluster_identifier" {
  value = aws_rds_cluster.main.cluster_identifier
}

output "security_group_id" {
  value = aws_security_group.rds.id
}

output "database_name" {
  value = aws_rds_cluster.main.database_name
}
