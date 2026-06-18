# AWS Production Deployment — GMX-Solana

## Background

GMX-Solana is a Solana-native protocol. The **on-chain programs** live on the Solana blockchain itself — AWS does not host them. What AWS hosts are all the **off-chain services** that make the protocol functional:

| What runs on AWS | Why |
|---|---|
| **Keeper services** (order executor, liquidator, ADL, GLV, deposit/withdrawal) | Without keepers, pending orders sit in escrow forever. Protocol stops working. |
| **Price cache daemon** | Continuously polls Pyth/Chainlink/Switchboard and maintains warm signed price data ready for instant injection into keeper transactions |
| **Public read API** | Serves market data, positions, order book, leaderboard — potentially millions of req/day |
| **WebSocket gateway** | Real-time price and position updates to end-users |
| **Indexer** | Listens to Solana program events, writes structured data to PostgreSQL for fast queries |

---

## Key Design Decisions

> [!IMPORTANT]
> **Keepers are NOT stateless HTTP services.** They are long-running, stateful Rust processes that maintain a warm price cache, hold keeper keypairs in memory, and scan Solana accounts continuously. EKS (Kubernetes) is the right platform, not Lambda.

> [!IMPORTANT]
> **Solana is the source of truth.** Per the KEEPER_PROPOSAL docs, the chain's PDA accounts are the durable queue. The keeper's AWS state (Redis, Postgres) is only a cache/index. If everything in AWS is wiped, the keeper restarts and re-scans chain state. This simplifies disaster recovery significantly.

> [!WARNING]
> **Keeper keypairs are high-value secrets.** A compromised keeper wallet could drain execution fee reserves. These must be stored in AWS Secrets Manager and injected as environment variables at runtime — never baked into container images or stored in config files.

---

## Open Questions

> [!IMPORTANT]
> **1. How many keeper instances?** The keeper proposal recommends single-instance V1 (chain is idempotent), then sharding by market for scale. Do you want multi-instance from day one with Redis-based distributed locking?

> [!IMPORTANT]
> **2. API authentication?** The public read API — is it fully open (like a block explorer) or do some endpoints require wallet-signature auth?

> [!IMPORTANT]
> **3. RPC provider?** Which Solana RPC provider will keepers use? (Helius, Triton, QuikNode, or your own validator node?) This affects egress architecture. Should we provision a dedicated RPC node on AWS (e.g., on a `r6i.8xlarge`)?

> [!IMPORTANT]
> **4. Regions?** Single-region (us-east-1) or multi-region active-active? Single-region is strongly recommended for V1 — Solana itself is global and a single well-connected region is sufficient.

> [!IMPORTANT]
> **5. Environments?** How many environments: `dev`, `staging`, `prod`? Terraform workspaces will be used to manage them, but the answer affects initial cost estimates.

---

## Proposed AWS Architecture

```
                        ┌─────────────────────────────────────────────────┐
                        │                   AWS VPC (us-east-1)            │
                        │  ┌──────────────┐    ┌──────────────────────┐   │
  Users/Traders ──────►│  │  CloudFront  │───►│   API Gateway (HTTP)  │   │
                        │  └──────────────┘    └──────────┬───────────┘   │
                        │                                 │               │
                        │  ┌──────────────────────────────▼─────────────┐ │
                        │  │    Public Subnet (2 AZs)                   │ │
                        │  │  ┌──────────────┐  ┌────────────────────┐  │ │
                        │  │  │  ALB (HTTPS) │  │  Lambda (Read API) │  │ │
                        │  │  └──────┬───────┘  └────────────────────┘  │ │
                        │  └─────────│──────────────────────────────────┘ │
                        │            │                                     │
                        │  ┌─────────▼──────────────────────────────────┐ │
                        │  │    Private Subnet (2 AZs)                  │ │
                        │  │                                            │ │
                        │  │  ┌─────────────────────────────────────┐  │ │
                        │  │  │        EKS Cluster                  │  │ │
                        │  │  │  ┌──────────────┐ ┌──────────────┐  │  │ │
                        │  │  │  │ Keeper Pod   │ │ Indexer Pod  │  │  │ │
                        │  │  │  │ (order/liq/  │ │ (Solana →    │  │  │ │
                        │  │  │  │  ADL/GLV)    │ │  Postgres)   │  │  │ │
                        │  │  │  └──────────────┘ └──────────────┘  │  │ │
                        │  │  │  ┌──────────────┐ ┌──────────────┐  │  │ │
                        │  │  │  │ Price Cache  │ │  WS Gateway  │  │  │ │
                        │  │  │  │    Daemon    │ │    Pod       │  │  │ │
                        │  │  │  └──────────────┘ └──────────────┘  │  │ │
                        │  │  └─────────────────────────────────────┘  │ │
                        │  │                                            │ │
                        │  │  ┌──────────────┐  ┌────────────────────┐  │ │
                        │  │  │ ElastiCache  │  │  Aurora PostgreSQL  │  │ │
                        │  │  │   (Redis)    │  │   (Multi-AZ)       │  │ │
                        │  │  │ Price Cache  │  │  Indexed State     │  │ │
                        │  │  └──────────────┘  └────────────────────┘  │ │
                        │  └────────────────────────────────────────────┘ │
                        │                                                 │
                        │  ┌─────────────────────────────────────────┐   │
                        │  │  Cross-Cutting Services                  │   │
                        │  │  Secrets Manager │ CloudWatch │ SNS/PD   │   │
                        │  └─────────────────────────────────────────┘   │
                        └─────────────────────────────────────────────────┘
                                           │
                                           ▼
                                   Solana Mainnet RPC
                               (Helius / Triton / QuikNode)
```

---

## Proposed Changes

### Infrastructure Layer

#### [NEW] `infra/terraform/` — Root Terraform directory

```
infra/terraform/
├── environments/
│   ├── prod/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── terraform.tfvars
│   ├── staging/
│   └── dev/
├── modules/
│   ├── vpc/              # VPC, subnets, NAT GW, IGW, route tables
│   ├── eks/              # EKS cluster, node groups, IRSA, addons
│   ├── rds/              # Aurora PostgreSQL (Multi-AZ)
│   ├── elasticache/      # Redis (cluster mode, Multi-AZ)
│   ├── ecr/              # Container registries per service
│   ├── alb/              # Application Load Balancer + target groups
│   ├── api-gateway/      # HTTP API Gateway + Lambda integrations
│   ├── lambda/           # Lambda functions for read APIs
│   ├── cloudfront/       # CDN distribution + WAF
│   ├── secrets/          # Secrets Manager secrets (keeper keypairs)
│   ├── iam/              # IAM roles, policies, IRSA bindings
│   ├── monitoring/       # CloudWatch dashboards, alarms, SNS topics
│   └── s3/               # ALT config bucket, terraform state bucket
└── bootstrap/            # One-time: S3 backend + DynamoDB lock table
```

---

### Module: `vpc`

**Resources:**
- VPC (`10.0.0.0/16`)
- 2 public subnets (one per AZ) — for ALB and NAT GW
- 4 private subnets (2 for EKS nodes, 2 for RDS/Redis)
- Internet Gateway, 2 NAT Gateways (one per AZ for HA)
- Route tables and associations
- VPC Flow Logs → CloudWatch Logs

---

### Module: `eks`

**Resources:**
- EKS Cluster (Kubernetes 1.31+)
- **Node Groups:**
  - `system` — `t3.medium` × 2, on-demand, for cluster add-ons
  - `keepers` — `c6i.2xlarge` × 2–4, on-demand, for keeper workloads (CPU-intensive Rust processes + RPC polling)
  - `api` — `t3.large` × 2–4, mixed on-demand/spot, for indexer & WS gateway
- IRSA (IAM Roles for Service Accounts) for pods to access Secrets Manager, CloudWatch
- EKS add-ons: CoreDNS, kube-proxy, VPC CNI, EBS CSI Driver, AWS Load Balancer Controller
- Cluster autoscaler (HPA + Karpenter)

**Kubernetes Workloads (Helm charts / manifests managed separately):**

| Deployment | Replicas | Resources | Description |
|---|---|---|---|
| `keeper-order` | 1–2 | 2 CPU / 2 GB | Executes market/limit orders, deposits, withdrawals |
| `keeper-liquidator` | 1–2 | 2 CPU / 2 GB | Scans positions, triggers liquidations |
| `keeper-adl` | 1 | 1 CPU / 1 GB | Runs two-step ADL (update_adl_state → auto_deleverage) |
| `keeper-glv` | 1 | 1 CPU / 1 GB | Executes GLV shifts |
| `price-cache-daemon` | 2 | 1 CPU / 1 GB | Continuously polls Pyth/Chainlink/Switchboard, writes to Redis |
| `indexer` | 1–2 | 2 CPU / 4 GB | Listens to Solana logs, writes to Aurora |
| `ws-gateway` | 2–4 | 1 CPU / 1 GB | WebSocket server for real-time updates |

---

### Module: `rds`

**Resources:**
- Aurora PostgreSQL (Serverless v2 or provisioned `db.r6g.large`)
- Multi-AZ (one writer + one reader replica)
- Automated backups, 7-day retention
- Parameter group with optimized WAL settings
- Subnet group in private subnets
- Security group: only EKS nodes + Lambda can connect on port 5432

**Schema (managed by the indexer service, not Terraform):**
- `orders` — all historical orders
- `positions` — current and historical positions
- `deposits` / `withdrawals` — liquidity actions
- `trades` — executed trade events from Solana program logs
- `markets` — market state snapshots
- `leaderboard` — competition scores

---

### Module: `elasticache`

**Resources:**
- Redis 7.x, cluster mode disabled (single shard, Multi-AZ with failover)
- `cache.r6g.large` for the price-cache daemon
- Subnet group in private subnets
- Security group: only EKS nodes can connect on port 6379
- Encryption in-transit (TLS) + at-rest

**Redis key schema:**
```
price:{token_mint}              → latest signed Pyth/Chainlink price blob + timestamp
price:{token_mint}:ttl          → 30s TTL (matches Solana oracle freshness window)
keeper:lock:{order_pubkey}      → distributed lock (10s TTL) to prevent double execution
market:{market_token}:state     → cached market account data
```

---

### Module: `api-gateway` + `lambda`

**Resources:**
- HTTP API Gateway (regional, with throttling: 10k req/sec burst, 5k steady-state)
- Lambda functions (Rust runtime via `cargo-lambda` / `provided.al2023`):
  - `fn-markets` — GET /markets, GET /markets/{token}
  - `fn-positions` — GET /positions/{wallet}
  - `fn-orders` — GET /orders/{wallet}
  - `fn-leaderboard` — GET /competition/leaderboard
  - `fn-prices` — GET /prices (reads from Redis via VPC endpoint)
- Lambda VPC configuration (private subnets)
- Lambda → RDS/Redis via Security Groups

> [!NOTE]
> Lambda is used for read-only API endpoints because they scale to millions of req/day automatically. Write operations (creating orders) go directly to Solana — not through this API.

---

### Module: `cloudfront`

**Resources:**
- CloudFront distribution
  - Origin 1: API Gateway (for `/api/*`)
  - Origin 2: S3 static website (if a frontend is deployed)
- Cache policies: 60s TTL for market/price data, no-cache for position data
- WAF (WebACL):
  - AWS Managed Rules (Core Rule Set, Known Bad Inputs)
  - Rate limiting: 1000 req/5min per IP
  - Geo-blocking (if required by compliance)
- Custom domain + ACM certificate (us-east-1)
- Access logging → S3

---

### Module: `secrets`

**Resources:**
- `gmsol/keeper/order-keypair` — Solana keypair JSON for order keeper wallet
- `gmsol/keeper/liquidator-keypair` — Solana keypair for liquidator wallet
- `gmsol/keeper/adl-keypair`
- `gmsol/keeper/glv-keypair`
- `gmsol/rpc/helius-api-key` — Solana RPC API key
- `gmsol/rpc/jito-auth-keypair` — JITO bundle submission keypair
- `gmsol/db/postgres-password`
- IRSA policy allowing EKS keeper pods to `GetSecretValue` on their specific secrets only

---

### Module: `monitoring`

**Resources:**
- CloudWatch Log Groups per service (30-day retention)
- CloudWatch Container Insights for EKS
- **Custom Metrics** (emitted by keeper services):
  - `gmsol/keeper/orders_executed_total`
  - `gmsol/keeper/orders_failed_total`
  - `gmsol/keeper/liquidations_executed_total`
  - `gmsol/keeper/tx_confirmation_latency_ms`
  - `gmsol/keeper/price_cache_staleness_ms`
  - `gmsol/keeper/pending_orders_count`
- **CloudWatch Alarms:**
  - `keeper-down` — no successful execution in 5 minutes → SNS → PagerDuty
  - `high-pending-orders` — pending orders > 50 for > 2 min → alert
  - `price-cache-stale` — price age > 25 seconds → critical alert
  - `lambda-error-rate` — error rate > 1% → alert
  - `rds-cpu-high` — CPU > 80% for 5 min → alert
- CloudWatch Dashboard: "GMSOL Keeper Health"
- SNS topics → PagerDuty / Slack integrations

---

### Module: `ecr`

- ECR repositories: `gmsol/keeper`, `gmsol/indexer`, `gmsol/ws-gateway`
- Lifecycle policies: keep last 10 images
- Image scanning on push (ECR enhanced scanning)

---

### Module: `s3`

- `gmsol-terraform-state-{account_id}` — Terraform remote state (versioned, encrypted)
- `gmsol-alts-{env}` — Address Lookup Table JSON exports for keepers
- `gmsol-logs-{env}` — CloudFront access logs

---

### Module: `iam`

- EKS cluster role + node group role
- IRSA roles per keeper service (least-privilege)
- Lambda execution role
- Cross-service policies (EKS nodes → ECR pull, Lambda → Secrets Manager read)

---

## Terraform Structure Details

### Remote State Bootstrap (`bootstrap/`)
```hcl
# Creates S3 bucket + DynamoDB table for Terraform state locking
# Run once manually before any other Terraform apply
```

### Root Module Pattern (per environment)
```hcl
# environments/prod/main.tf
module "vpc"         { source = "../../modules/vpc" ... }
module "eks"         { source = "../../modules/eks" ... }
module "rds"         { source = "../../modules/rds" ... }
module "elasticache" { source = "../../modules/elasticache" ... }
module "ecr"         { source = "../../modules/ecr" ... }
module "secrets"     { source = "../../modules/secrets" ... }
module "alb"         { source = "../../modules/alb" ... }
module "lambda"      { source = "../../modules/lambda" ... }
module "api_gateway" { source = "../../modules/api-gateway" ... }
module "cloudfront"  { source = "../../modules/cloudfront" ... }
module "monitoring"  { source = "../../modules/monitoring" ... }
module "iam"         { source = "../../modules/iam" ... }
```

### CI/CD (GitHub Actions)
```
PR → terraform fmt + validate + plan (posted as PR comment)
Merge to main (staging) → terraform apply (staging)
Manual approval → terraform apply (prod)
Docker build → ECR push → kubectl rollout restart
```

---

## Capacity & Cost Estimate (prod, us-east-1)

| Service | Config | Est. Monthly |
|---|---|---|
| EKS cluster | 2 t3.medium + 4 c6i.2xlarge | ~$750 |
| Aurora PostgreSQL | db.r6g.large Multi-AZ | ~$280 |
| ElastiCache Redis | cache.r6g.large Multi-AZ | ~$180 |
| NAT Gateways (2) | + data transfer | ~$100 |
| Lambda | ~30M invocations/month | ~$60 |
| API Gateway | ~30M req/month | ~$100 |
| CloudFront | ~1 TB transfer | ~$85 |
| ALB | + LCU | ~$25 |
| Secrets Manager | 10 secrets | ~$5 |
| CloudWatch | Logs + metrics | ~$80 |
| ECR | Storage + transfer | ~$20 |
| **Total estimate** | | **~$1,700/month** |

---

## Verification Plan

### Automated
- `terraform validate` and `terraform plan` on every PR
- `checkov` static analysis on Terraform files
- EKS pod health checks via liveness/readiness probes
- CloudWatch alarm smoke tests after apply

### Manual
- Deploy to `staging` first; run keeper against Solana devnet for 24h
- Verify order execution end-to-end: create order on devnet → keeper picks up → executes
- Verify liquidation: open under-collateralised position → confirm liquidation fires
- Load test API endpoints with k6 (target: 1000 req/sec sustained)
- Verify failover: terminate keeper pod → new pod comes up, re-scans chain, resumes execution
