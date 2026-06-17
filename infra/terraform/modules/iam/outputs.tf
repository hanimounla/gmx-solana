output "eks_cluster_role_arn" {
  value = aws_iam_role.eks_cluster.arn
}

output "eks_node_group_role_arn" {
  value = aws_iam_role.eks_node_group.arn
}

output "irsa_keeper_order_role_arn" {
  value = aws_iam_role.keeper_order.arn
}

output "irsa_keeper_liquidator_role_arn" {
  value = aws_iam_role.keeper_liquidator.arn
}

output "irsa_keeper_adl_role_arn" {
  value = aws_iam_role.keeper_adl.arn
}

output "irsa_keeper_glv_role_arn" {
  value = aws_iam_role.keeper_glv.arn
}

output "irsa_price_cache_role_arn" {
  value = aws_iam_role.price_cache.arn
}

output "lambda_exec_role_arn" {
  value = aws_iam_role.lambda_exec.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}
