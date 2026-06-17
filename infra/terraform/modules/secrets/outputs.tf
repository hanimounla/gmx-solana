output "keeper_order_keypair_arn" { value = aws_secretsmanager_secret.keeper_order_keypair.arn }
output "keeper_liquidator_keypair_arn" { value = aws_secretsmanager_secret.keeper_liquidator_keypair.arn }
output "keeper_adl_keypair_arn" { value = aws_secretsmanager_secret.keeper_adl_keypair.arn }
output "keeper_glv_keypair_arn" { value = aws_secretsmanager_secret.keeper_glv_keypair.arn }
output "rpc_helius_api_key_arn" { value = aws_secretsmanager_secret.rpc_helius_api_key.arn }
output "rpc_jito_keypair_arn" { value = aws_secretsmanager_secret.rpc_jito_keypair.arn }
output "db_password_arn" { value = aws_secretsmanager_secret.db_password.arn }
output "redis_auth_token_arn" { value = aws_secretsmanager_secret.redis_auth_token.arn }
