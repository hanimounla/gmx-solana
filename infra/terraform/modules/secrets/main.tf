###############################################################################
# Module: Secrets Manager
#
# Creates placeholder secrets for all keeper and service credentials.
# Actual secret values are populated out-of-band (manually or via CI/CD)
# using `aws secretsmanager put-secret-value`.
#
# NEVER store real keypairs in Terraform state.
###############################################################################

resource "aws_secretsmanager_secret" "keeper_order_keypair" {
  name                    = "gmsol/keeper/order-keypair"
  description             = "Solana keypair JSON for the order keeper wallet"
  recovery_window_in_days = 30

  tags = {
    Name      = "gmsol-keeper-order-keypair"
    Sensitive = "true"
  }
}

resource "aws_secretsmanager_secret" "keeper_liquidator_keypair" {
  name                    = "gmsol/keeper/liquidator-keypair"
  description             = "Solana keypair JSON for the liquidator keeper wallet"
  recovery_window_in_days = 30

  tags = {
    Name      = "gmsol-keeper-liquidator-keypair"
    Sensitive = "true"
  }
}

resource "aws_secretsmanager_secret" "keeper_adl_keypair" {
  name                    = "gmsol/keeper/adl-keypair"
  description             = "Solana keypair JSON for the ADL keeper wallet"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "keeper_glv_keypair" {
  name                    = "gmsol/keeper/glv-keypair"
  description             = "Solana keypair JSON for the GLV keeper wallet"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "rpc_helius_api_key" {
  name                    = "gmsol/rpc/helius-api-key"
  description             = "Helius RPC API key for Solana mainnet access"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "rpc_jito_keypair" {
  name                    = "gmsol/rpc/jito-auth-keypair"
  description             = "JITO bundle submission auth keypair"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "gmsol/db/postgres-password"
  description             = "Aurora PostgreSQL master password"
  recovery_window_in_days = 30
}

resource "aws_secretsmanager_secret" "redis_auth_token" {
  name                    = "gmsol/cache/redis-auth-token"
  description             = "Redis TLS auth token"
  recovery_window_in_days = 30
}

###############################################################################
# Placeholder values (will be overwritten out-of-band)
###############################################################################

resource "aws_secretsmanager_secret_version" "keeper_order_keypair" {
  secret_id     = aws_secretsmanager_secret.keeper_order_keypair.id
  secret_string = jsonencode({ note = "Replace with actual keypair JSON. See RUNBOOK.md." })

  lifecycle {
    ignore_changes = [secret_string] # Don't overwrite real values on re-apply
  }
}

resource "aws_secretsmanager_secret_version" "keeper_liquidator_keypair" {
  secret_id     = aws_secretsmanager_secret.keeper_liquidator_keypair.id
  secret_string = jsonencode({ note = "Replace with actual keypair JSON. See RUNBOOK.md." })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret_version" "keeper_adl_keypair" {
  secret_id     = aws_secretsmanager_secret.keeper_adl_keypair.id
  secret_string = jsonencode({ note = "Replace with actual keypair JSON. See RUNBOOK.md." })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret_version" "keeper_glv_keypair" {
  secret_id     = aws_secretsmanager_secret.keeper_glv_keypair.id
  secret_string = jsonencode({ note = "Replace with actual keypair JSON. See RUNBOOK.md." })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret_version" "rpc_helius_api_key" {
  secret_id     = aws_secretsmanager_secret.rpc_helius_api_key.id
  secret_string = jsonencode({ api_key = "REPLACE_ME" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_secretsmanager_secret_version" "rpc_jito_keypair" {
  secret_id     = aws_secretsmanager_secret.rpc_jito_keypair.id
  secret_string = jsonencode({ note = "Replace with JITO auth keypair JSON." })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
