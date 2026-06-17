# GMSOL Infrastructure — Operator Runbook

## Architecture Overview

```
CloudFront (CDN + WAF)
       │
       ├──/api/*──► API Gateway ──► Lambda (markets, positions, orders, prices, leaderboard)
       │                                      │
       └──/ws/*───► ALB ──► EKS ──► ws-gateway pods
                                │
                                ├── keeper-order       (order execution)
                                ├── keeper-liquidator  (position health + liquidation)
                                ├── keeper-adl         (auto-deleverage)
                                ├── keeper-glv         (GLV shift rebalancing)
                                └── price-cache-daemon (oracle price polling → Redis)
                                              │
                              ┌───────────────┴────────────────┐
                         ElastiCache (Redis)          Aurora PostgreSQL
                         Price cache + locks          Indexed trading data
```

All keeper services connect outbound to:
- **Solana Mainnet RPC** (Helius) for chain reads/writes
- **JITO** for MEV-aware bundle submission

---

## Day 1 Setup

### Prerequisites
- AWS CLI configured with admin access
- Terraform >= 1.7.0
- kubectl
- `jq`, `aws-cli`

### Step 1: Bootstrap Remote State

```bash
cd infra/terraform/bootstrap
terraform init
terraform apply -var="aws_account_id=$(aws sts get-caller-identity --query Account --output text)"
```

### Step 2: Provision Secrets (BEFORE applying main infrastructure)

```bash
# Upload keeper keypairs (generate with: solana-keygen new -o /tmp/order-keeper.json)
aws secretsmanager put-secret-value \
  --secret-id gmsol/keeper/order-keypair \
  --secret-string file:///path/to/order-keeper.json

aws secretsmanager put-secret-value \
  --secret-id gmsol/keeper/liquidator-keypair \
  --secret-string file:///path/to/liquidator-keeper.json

aws secretsmanager put-secret-value \
  --secret-id gmsol/keeper/adl-keypair \
  --secret-string file:///path/to/adl-keeper.json

aws secretsmanager put-secret-value \
  --secret-id gmsol/keeper/glv-keypair \
  --secret-string file:///path/to/glv-keeper.json

# Upload RPC API key
aws secretsmanager put-secret-value \
  --secret-id gmsol/rpc/helius-api-key \
  --secret-string '{"api_key":"YOUR_HELIUS_API_KEY"}'

# Upload JITO keypair
aws secretsmanager put-secret-value \
  --secret-id gmsol/rpc/jito-auth-keypair \
  --secret-string file:///path/to/jito-keypair.json
```

### Step 3: Provision Infrastructure

```bash
cd infra/terraform/environments/prod

# Export sensitive vars (never put these in tfvars)
export TF_VAR_db_master_password="$(openssl rand -base64 32)"
export TF_VAR_redis_auth_token="$(openssl rand -base64 32)"
export TF_VAR_pagerduty_endpoint="https://events.pagerduty.com/..."
export TF_VAR_slack_webhook_url="https://hooks.slack.com/..."

# Store the passwords in Secrets Manager before applying
aws secretsmanager put-secret-value \
  --secret-id gmsol/db/postgres-password \
  --secret-string "$TF_VAR_db_master_password"

aws secretsmanager put-secret-value \
  --secret-id gmsol/cache/redis-auth-token \
  --secret-string "$TF_VAR_redis_auth_token"

terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

### Step 4: Configure kubectl

```bash
# Use the output from terraform apply
aws eks update-kubeconfig --region us-east-1 --name gmsol-prod
kubectl get nodes
```

### Step 5: Create Redis connection secret for pods

```bash
REDIS_ENDPOINT=$(terraform output -raw redis_primary_endpoint)
REDIS_TOKEN=$(aws secretsmanager get-secret-value --secret-id gmsol/cache/redis-auth-token --query SecretString --output text)

kubectl create secret generic redis-connection \
  --namespace gmsol \
  --from-literal=url="rediss://:${REDIS_TOKEN}@${REDIS_ENDPOINT}:6379"
```

### Step 6: Deploy Keeper Services

```bash
# Apply namespace first
kubectl apply -f infra/k8s/namespace.yaml

# Substitute ECR registry URL and IRSA role ARNs in manifests
ECR_REGISTRY=$(terraform output -raw ecr_registry_id).dkr.ecr.us-east-1.amazonaws.com
IRSA_ORDER=$(terraform output -raw irsa_keeper_order_role_arn)
IRSA_LIQ=$(terraform output -raw irsa_keeper_liquidator_role_arn)
IRSA_PRICE=$(terraform output -raw irsa_price_cache_role_arn)

# Use envsubst or kustomize to substitute values, then apply
envsubst < infra/k8s/keeper-order/deployment.yaml | kubectl apply -f -
envsubst < infra/k8s/keeper-liquidator/deployment.yaml | kubectl apply -f -
envsubst < infra/k8s/price-cache-daemon/deployment.yaml | kubectl apply -f -
envsubst < infra/k8s/ws-gateway/deployment.yaml | kubectl apply -f -
```

---

## Day-to-Day Operations

### Viewing Keeper Logs

```bash
# Live logs from order keeper
kubectl logs -f deployment/keeper-order -n gmsol

# Last 100 errors from liquidator
kubectl logs deployment/keeper-liquidator -n gmsol | grep ERROR | tail -100

# Price cache staleness events
kubectl logs deployment/price-cache-daemon -n gmsol | grep PRICE_STALE
```

### Checking Keeper Health

```bash
# Pod status
kubectl get pods -n gmsol

# Keeper metrics (if port-forwarded)
kubectl port-forward deployment/keeper-order 9090:9090 -n gmsol
curl http://localhost:9090/metrics
```

### Emergency: Pause Order Execution

If you need to halt keeper execution immediately (e.g., protocol issue):

```bash
# Scale down (pods drain gracefully)
kubectl scale deployment keeper-order --replicas=0 -n gmsol
kubectl scale deployment keeper-liquidator --replicas=0 -n gmsol

# Resume
kubectl scale deployment keeper-order --replicas=1 -n gmsol
kubectl scale deployment keeper-liquidator --replicas=1 -n gmsol
```

> [!WARNING]
> During the pause, pending orders accumulate on-chain. When you resume, the keeper
> will re-scan all pending PDAs and execute them in priority order. Monitor for
> sudden spike in transactions.

### Rotating Keeper Keypairs

```bash
# 1. Generate new keypair
solana-keygen new -o /tmp/new-order-keeper.json

# 2. Fund the new keypair on-chain (for transaction fees)
solana transfer /tmp/new-order-keeper.json 1 --allow-unfunded-recipient

# 3. Grant the new address MARKET_KEEPER role via timelock (or admin)
gmsol admin grant-role --role ORDER_KEEPER --user $(solana-keygen pubkey /tmp/new-order-keeper.json)

# 4. Update Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id gmsol/keeper/order-keypair \
  --secret-string file:///tmp/new-order-keeper.json

# 5. Restart keeper pod to pick up new secret
kubectl rollout restart deployment/keeper-order -n gmsol

# 6. Revoke old keypair role after confirming new keeper is healthy
gmsol admin revoke-role --role ORDER_KEEPER --user <OLD_PUBKEY>
```

---

## CloudWatch Alarms Reference

| Alarm | Severity | Meaning | Action |
|---|---|---|---|
| `keeper-order-DOWN` | 🔴 CRITICAL | No orders executed in 5 min | Check pod logs, Solana RPC status |
| `keeper-liquidator-DOWN` | 🔴 CRITICAL | No position scans in 5 min | Check pod logs, Redis connectivity |
| `PRICE-CACHE-STALE` | 🔴 CRITICAL | Oracle prices older than 20s | Check price-cache-daemon logs, Pyth/Chainlink status |
| `HIGH-PENDING-ORDERS` | 🟡 WARNING | >50 orders queued for >2 min | Check keeper throughput, JITO tips |
| `rds-high-cpu` | 🟡 WARNING | RDS CPU >80% | Check indexer query patterns, consider scaling |
| `redis-high-memory` | 🟡 WARNING | Redis memory >80% | Consider upgrading cache.r6g.xlarge |
| `lambda-error-rate` | 🟡 WARNING | Lambda errors >100/min | Check API logs |

---

## Cost Optimisation Tips

- **Staging**: Scale keeper node group to 0 when not testing (`kubectl scale...`)
- **Dev**: Use `cache.t3.micro` Redis and `db.serverless` with 0 min ACUs
- **Spot interruptions**: Only api/indexer node group uses Spot — keepers are always ON_DEMAND
- **CloudFront**: `PriceClass_100` (US+EU only) saves ~30% vs global

---

## Disaster Recovery

Since **Solana is the source of truth**, AWS is stateless from a protocol perspective.

If the entire AWS environment is lost:
1. Restore Terraform state from S3 versioned backup
2. Run `terraform apply` — infrastructure is rebuilt in ~20 minutes
3. Re-upload keeper keypairs to Secrets Manager (from secure offline backup)
4. Deploy keeper pods — they re-scan all on-chain PDAs and resume execution
5. No data loss for on-chain state (orders, positions, markets)
6. PostgreSQL indexed data: restore from automated Aurora snapshot (≤24h old)

RPO: ~24h (indexed data). RTO: ~30 minutes (keeper services).
