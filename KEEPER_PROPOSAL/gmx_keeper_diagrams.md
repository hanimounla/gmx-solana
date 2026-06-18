# GMX-Solana: Architecture Diagram — Keeper Focus

> How the protocol runs, what calls what, and where the Keeper lives in all of it.

---

## Diagram 1 — Big Picture: Who Does What

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              GMX-SOLANA SYSTEM                                      │
│                                                                                     │
│  ┌──────────────┐        Step 1: Create Request        ┌──────────────────────────┐ │
│  │              │ ─────────────────────────────────────▶│   ON-CHAIN PROGRAM       │ │
│  │    USER      │                                       │   gmsol-store            │ │
│  │  (Wallet)    │                                       │                          │ │
│  │              │◀─────────────────────────────────────│  Creates PDA accounts:   │ │
│  └──────────────┘     Tokens sit in escrow PDAs         │  Order / Deposit /       │ │
│                       User waits...                     │  Withdrawal / Shift      │ │
│                                                         │                          │ │
│                                                         └────────────┬─────────────┘ │
│                                                                      │               │
│                                              Step 2: Execute         │               │
│  ┌──────────────────────────────────────────────────────────────────┘               │
│  │                                                                                   │
│  ▼                                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐ │
│  │                            OFF-CHAIN KEEPER SERVICE                             │ │
│  │                                                                                 │ │
│  │   1. Watch chain for pending PDAs                                               │ │
│  │   2. Fetch oracle prices (Pyth / Chainlink / Switchboard)                       │ │
│  │   3. Build execution transaction (with remaining_accounts)                      │ │
│  │   4. Submit → collect execution fee                                             │ │
│  └─────────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Diagram 2 — Repository Layout (Keeper-Relevant Files Only)

```
gmx-solana/
│
├── programs/
│   └── store/src/
│       ├── lib.rs                          ← Program entrypoint, all instruction dispatchers
│       │
│       ├── instructions/exchange/          ← 🔴 KEEPER CALLS THESE
│       │   ├── execute_order.rs            ← execute_increase_or_swap_order_v2
│       │   │                                  execute_decrease_order_v2
│       │   ├── execute_deposit.rs          ← execute_deposit
│       │   ├── execute_withdrawal.rs       ← execute_withdrawal
│       │   ├── position_cut.rs             ← liquidate / auto_deleverage
│       │   ├── update_adl.rs               ← update_adl_state (before ADL)
│       │   ├── execute_shift.rs            ← execute_shift (GLV rebalance)
│       │   ├── update_fees.rs              ← update_fees_state
│       │   └── update_closed.rs            ← update_closed_state
│       │
│       ├── states/                         ← On-chain account structures
│       │   ├── order.rs                    ← Order { kind, params, tokens, swap }
│       │   ├── market/                     ← Market { pools, open_interest, adl_flag }
│       │   ├── glv.rs                      ← Glv, GlvDeposit, GlvWithdrawal
│       │   ├── oracle.rs                   ← Oracle buffer (filled by Keeper per-tx)
│       │   └── store.rs                    ← Store (global config, recent_time_window)
│       │
│       └── ops/                            ← Business logic (called from instructions)
│           ├── order.rs                    ← ExecuteOrderOperation (math, price impact)
│           ├── deposit.rs                  ← ExecuteDepositOperation
│           ├── withdrawal.rs               ← ExecuteWithdrawalOperation
│           └── execution_fee.rs            ← PayExecutionFeeOperation (Keeper's reward)
│
└── crates/
    └── sdk/src/
        ├── client/
        │   ├── mod.rs                      ← Client struct (RPC + PubSub)
        │   ├── pubsub.rs                   ← 🔵 WebSocket log subscription
        │   ├── accounts.rs                 ← getProgramAccounts helpers
        │   │
        │   └── ops/exchange/               ← 🔵 SDK wrappers (Keeper uses these)
        │       ├── mod.rs                  ← ExchangeOps trait (all Keeper actions)
        │       ├── order.rs                ← ExecuteOrderBuilder, PositionCutBuilder
        │       ├── deposit.rs              ← ExecuteDepositBuilder
        │       ├── withdrawal.rs           ← ExecuteWithdrawalBuilder
        │       ├── shift.rs                ← ExecuteShiftBuilder
        │       ├── glv_deposit.rs          ← ExecuteGlvDepositBuilder
        │       ├── glv_withdrawal.rs       ← ExecuteGlvWithdrawalBuilder
        │       └── glv_shift.rs            ← ExecuteGlvShiftBuilder
        │
        ├── client/pull_oracle.rs           ← 🔵 Fetch prices from oracle providers
        ├── client/pyth/                    ← Pyth price feed integration
        ├── client/chainlink/               ← Chainlink Data Streams integration
        └── client/switchboard/             ← Switchboard integration
```

**Legend:** 🔴 = On-chain code the Keeper triggers | 🔵 = Off-chain SDK the Keeper uses

---

## Diagram 3 — The Two-Step Model (Core Mechanic)

```
STEP 1: USER creates a request
────────────────────────────────────────────────────────────────────

  User Wallet
      │
      │  create_order(kind=MarketIncrease, collateral=100 USDC, size=$1000)
      ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  gmsol-store program                                        │
  │                                                             │
  │  Creates:                                                   │
  │  ┌──────────────────────────────────────────────────────┐  │
  │  │  Order PDA                                           │  │
  │  │  address = PDA[b"order", store, user, nonce]         │  │
  │  │                                                      │  │
  │  │  kind:           MarketIncrease                      │  │
  │  │  side:           Long                                │  │
  │  │  collateral:     100 USDC (in escrow ATA)            │  │
  │  │  size_delta_usd: 1000_000_000_000_000_000_000 (u128) │  │
  │  │  acceptable_price: u128::MAX (market order)          │  │
  │  │  trigger_price:  0 (no trigger for market)           │  │
  │  │  execution_fee:  300_000 lamports (for keeper)       │  │
  │  └──────────────────────────────────────────────────────┘  │
  │                                                             │
  │  Also creates:  Escrow ATAs (owned by Order PDA)           │
  │    - initial_collateral_token_escrow (holds user's USDC)   │
  │    - long_token_escrow, short_token_escrow (for outputs)   │
  └─────────────────────────────────────────────────────────────┘

STEP 2: KEEPER executes it
────────────────────────────────────────────────────────────────────

  Keeper detects Order PDA
      │
      ├─ reads order.kind, order.params, order.swap (swap path)
      ├─ fetches oracle prices for all tokens
      └─ builds and sends execute_increase_or_swap_order_v2

  On-chain execution flow:
  ┌─────────────────────────────────────────────────────────────┐
  │  1. transfer_tokens_in()                                    │
  │     USDC: escrow ATA → market vault                         │
  │                                                             │
  │  2. Oracle.with_prices()                                    │
  │     Validate price feeds from remaining_accounts            │
  │     Load prices into Oracle buffer                          │
  │                                                             │
  │  3. ExecuteOrderOperation.execute()                         │
  │     Compute: fees, price impact, acceptable_price check     │
  │     Update: Position account (size, collateral, entry_px)  │
  │     Update: Market account (open_interest, pools)          │
  │     Produce: TransferOut struct                             │
  │                                                             │
  │  4. if executed:                                            │
  │     process_transfer_out() → move tokens to user escrow    │
  │     order.header.completed()                                │
  │  else:                                                      │
  │     transfer_tokens_out() → refund collateral              │
  │     order.header.cancelled()                                │
  │                                                             │
  │  5. PayExecutionFeeOperation                               │
  │     Order PDA lamports → Keeper wallet (reward)            │
  └─────────────────────────────────────────────────────────────┘
```

---

## Diagram 4 — Keeper Internal Architecture

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                              KEEPER SERVICE INTERNALS                                │
│                                                                                      │
│  ┌───────────────────────────────┐     ┌──────────────────────────────────────────┐  │
│  │       CHAIN WATCHER           │     │           PRICE CACHE                    │  │
│  │                               │     │                                          │  │
│  │  WebSocket (pubsub.rs)        │     │  Background task, continuous refresh     │  │
│  │  ├─ logs_subscribe()          │     │                                          │  │
│  │  │  monitors gmsol-store      │     │  Pyth   → signed VAA reports            │  │
│  │  │  program log events        │     │  Chainlink → Data Streams updates        │  │
│  │  │                            │     │  Switchboard → pull oracle reports       │  │
│  │  └─ Fallback Polling          │     │                                          │  │
│  │     getProgramAccounts()      │     │  price_cache: HashMap<Pubkey, PriceFeed> │  │
│  │     every ~15 seconds         │     │  (keyed by token mint)                   │  │
│  │     filter by discriminator   │     │  expires after ~25s (before 30s window)  │  │
│  └──────────┬────────────────────┘     └──────────────────┬───────────────────────┘  │
│             │                                             │                          │
│             │  Pending PDAs detected                      │  Fresh prices ready      │
│             ▼                                             ▼                          │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐  │
│  │                         PRIORITY EXECUTION QUEUE                                │  │
│  │                                                                                 │  │
│  │   Priority 1 (CRITICAL):   Liquidation candidates                              │  │
│  │   Priority 2 (HIGH):       Market orders (MarketIncrease/Decrease/Swap)        │  │
│  │   Priority 3 (MEDIUM):     Deposits / Withdrawals / GLV Deposits               │  │
│  │   Priority 4 (LOW):        Limit/StopLoss orders (check trigger price first)   │  │
│  │   Priority 5 (BACKGROUND): GLV Shifts, ADL state updates                       │  │
│  └──────────────────────────────┬──────────────────────────────────────────────────┘  │
│                                 │                                                    │
│                                 ▼                                                    │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐ │
│  │                       TRANSACTION BUILDER                                        │ │
│  │                                                                                  │ │
│  │  For each pending action:                                                        │ │
│  │                                                                                  │ │
│  │  1. Determine action type → pick SDK builder                                    │ │
│  │     ExchangeOps::execute_order()     → ExecuteOrderBuilder                      │ │
│  │     ExchangeOps::execute_deposit()   → ExecuteDepositBuilder                    │ │
│  │     ExchangeOps::liquidate()         → PositionCutBuilder                       │ │
│  │     ExchangeOps::auto_deleverage()   → PositionCutBuilder                       │ │
│  │     ExchangeOps::update_adl()        → UpdateAdlBuilder                         │ │
│  │                                                                                  │ │
│  │  2. Build remaining_accounts in order:                                           │ │
│  │     [feed_0, feed_1, ..., market_1, market_2, ..., virtual_inv_0, ...]          │ │
│  │     Uses: swap.to_feeds(&token_map) to determine token list                     │ │
│  │                                                                                  │ │
│  │  3. Apply Address Lookup Tables (ALTs) if tx would exceed 1232 bytes             │ │
│  │     Uses: BundleBuilder (crates/sdk/src/client/ops/alt.rs)                      │ │
│  │                                                                                  │ │
│  │  4. Set priority fee based on network conditions                                 │ │
│  └──────────────────────────────┬───────────────────────────────────────────────────┘ │
│                                 │                                                    │
│                                 ▼                                                    │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐ │
│  │                         SUBMITTER + RETRY LOGIC                                  │ │
│  │                                                                                  │ │
│  │  send_and_confirm_transaction()                                                  │ │
│  │                                                                                  │ │
│  │  On success: log execution fee collected, mark order as done                     │ │
│  │  On failure (price expired):  re-fetch prices, retry                             │ │
│  │  On failure (order cancelled): log, skip (order was auto-cancelled on-chain)     │ │
│  │  On failure (already executed): skip (another keeper beat us)                   │ │
│  └──────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                      │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐ │
│  │                   POSITION HEALTH MONITOR (Separate async task)                  │ │
│  │                                                                                  │ │
│  │  Poll all Position accounts (getProgramAccounts filtered by store)               │ │
│  │  For each position:                                                              │ │
│  │    collateral_usd = collateral_amount × oracle_price                             │ │
│  │    losses = (entry_price - current_price) × size / entry_price  [for longs]     │ │
│  │    health = (collateral_usd - losses) / (size_in_usd)                           │ │
│  │    if health < MIN_COLLATERAL_FACTOR → add to liquidation queue (Priority 1)    │ │
│  └──────────────────────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Diagram 5 — Liquidation Flow (Most Complex Keeper Path)

```
Position becomes unhealthy
        │
        ▼
Keeper Health Monitor detects it
        │
        ├─ Derives claimable account addresses (time-keyed PDAs):
        │    address = PDA[b"claimable", store, long_token, owner, time_key]
        │    ⚠️  time_key changes every ~30s (recent_time_window)
        │        If tx lands in next window → wrong PDA → tx fails
        │
        ├─ Generates random nonce (32 bytes)
        ├─ Derives Order PDA for this liquidation:
        │    address = PDA[b"order", store, keeper_wallet, nonce]
        │
        └─ Builds single atomic transaction:
           ┌─────────────────────────────────────────────────────┐
           │  Instruction 1: Create long_token_escrow ATA        │
           │    (associated_token::create for Order PDA)         │
           │                                                     │
           │  Instruction 2: Create short_token_escrow ATA       │
           │    (associated_token::create for Order PDA)         │
           │                                                     │
           │  Instruction 3: liquidate()                         │
           │    accounts: authority (keeper), store, oracle,     │
           │              market, position, order (new),         │
           │              long/short escrows, vaults,            │
           │              claimable_long/short_for_user,         │
           │              claimable_pnl_for_holding              │
           │    remaining: [price_feed_0, ..., virtual_inv_0, ...]│
           └─────────────────────────────────────────────────────┘

On-chain liquidation (position_cut.rs → PositionCutOperation):
        │
        ├─ Validates feature: DomainDisabledFlag::Liquidation
        ├─ Loads prices from remaining_accounts via Oracle buffer
        ├─ Creates Order account (init'd within same tx)
        ├─ Executes position decrease at current market price
        ├─ Distributes collateral:
        │   remaining → owner's long/short_token_escrow
        │   funding fees → claimable accounts (time-keyed)
        │   price impact diff → holding address
        └─ PayExecutionFeeOperation → Keeper gets SOL refund
           (includes order rent + execution fee for liquidation)
```

---

## Diagram 6 — ADL (Auto-Deleveraging) Flow

```
Market has too many profitable longs/shorts (PnL > pool threshold)
        │
        ▼
Keeper ADL Monitor
        │
        ├─ Step A: update_adl_state  (REQUIRED FIRST)
        │          ┌────────────────────────────────────────┐
        │          │  update_adl_state(market, is_long)     │
        │          │  → fetches prices via remaining_accounts│
        │          │  → recomputes: pnl_to_pool_factor       │
        │          │  → sets: market.adl_enabled flag        │
        │          └────────────────────────────────────────┘
        │
        └─ Step B: If ADL flag still ON → auto_deleverage
                   ┌────────────────────────────────────────┐
                   │  auto_deleverage(position, size_delta)  │
                   │  → same flow as liquidation             │
                   │  → but keeper does NOT get execution fee│
                   │     (only rent refund, no reward)       │
                   │  ⚠️  If market recovers between A and B,│
                   │     ADL flag flips off → tx fails       │
                   │     → Keeper must handle gracefully     │
                   └────────────────────────────────────────┘
```

---

## Diagram 7 — The `remaining_accounts` Assembly (Most Error-Prone)

```
Every execution transaction requires remaining_accounts in EXACT order:

For execute_increase_or_swap_order_v2:
┌──────────────────────────────────────────────────────────────────┐
│  remaining_accounts = [                                          │
│                                                                  │
│    // Slot 0..M:  Price feed accounts (READ ONLY)                │
│    feed_for_index_token,      // e.g. Pyth SOL/USD account       │
│    feed_for_collateral_token, // e.g. Pyth USDC/USD account      │
│    feed_for_swap_token_1,     // if swap path has intermediate   │
│    ...                                                           │
│    // Count M = swap.to_feeds(&token_map).tokens.len()           │
│                                                                  │
│    // Slot M..M+N:  Market accounts (WRITABLE)                   │
│    market_for_swap_hop_1,     // NOT the primary market          │
│    market_for_swap_hop_2,     // (primary market is in accounts) │
│    ...                                                           │
│    // Count N = unique swap markets excluding primary            │
│                                                                  │
│    // Slot M+N..M+N+V:  Virtual inventory accounts (WRITABLE)   │
│    virtual_inventory_for_swaps_0,                                │
│    virtual_inventory_for_positions_0,                            │
│    ...                                                           │
│    // Count V = virtual inventories needed by swap markets       │
│  ]                                                               │
└──────────────────────────────────────────────────────────────────┘

⚠️  Getting this order wrong = silent failure ("invalid price feed")
    The SDK's swap.to_feeds(&token_map) helps determine M
    The BundleBuilder + ALT handles the tx size limit issue
```

---

## Diagram 8 — Oracle Price Freshness / Time Key Race Condition

```
Timeline (each block ≈ 400ms, time_window = 30 seconds):

t=0s     t=5s              t=30s    t=35s
 │        │                  │        │
 ▼        ▼                  ▼        ▼
[Window 1: time_key = "aaa"][Window 2: time_key = "bbb"]

Keeper at t=5s:
  1. Computes claimable PDA using time_key = "aaa"  ← PDA address A
  2. Fetches oracle prices (fresh)
  3. Builds transaction, submits

  Case A: Lands at t=7s  ✅
    → time_key "aaa" still valid → PDA A exists → SUCCESS

  Case B: Network congested, lands at t=32s  ❌
    → time_key "aaa" expired → PDA A has wrong address
    → Transaction fails with "invalid account" or "constraint violated"
    → Keeper must:
       a. Re-fetch prices
       b. Recompute claimable PDA with new time_key = "bbb"
       c. Create PDA B if it doesn't exist yet (costs rent)
       d. Re-submit

This is the hardest operational failure mode to handle correctly.
```

---

## Diagram 9 — Complete SDK Call Map (What the Keeper Actually Calls)

```
ExchangeOps trait  (crates/sdk/src/client/ops/exchange/mod.rs)
│
├── execute_order()         → ExecuteOrderBuilder  (ops/exchange/order.rs)
│   Uses:                     → gmsol_store::execute_increase_or_swap_order_v2
│                             → gmsol_store::execute_decrease_order_v2
│
├── execute_deposit()       → ExecuteDepositBuilder (ops/exchange/deposit.rs)
│   Uses:                     → gmsol_store::execute_deposit
│
├── execute_withdrawal()    → ExecuteWithdrawalBuilder (ops/exchange/withdrawal.rs)
│   Uses:                     → gmsol_store::execute_withdrawal
│
├── liquidate()             → PositionCutBuilder (ops/exchange/order.rs)
│   Uses:                     → gmsol_store::liquidate
│
├── auto_deleverage()       → PositionCutBuilder (ops/exchange/order.rs)
│   Uses:                     → gmsol_store::auto_deleverage
│
├── update_adl()            → UpdateAdlBuilder (ops/exchange/order.rs)
│   Uses:                     → gmsol_store::update_adl_state
│
├── execute_shift()         → ExecuteShiftBuilder (ops/exchange/shift.rs)
│   Uses:                     → gmsol_store::execute_shift
│
├── execute_glv_deposit()   → ExecuteGlvDepositBuilder (ops/exchange/glv_deposit.rs)
│   Uses:                     → gmsol_store::execute_glv_deposit
│
├── execute_glv_withdrawal()→ ExecuteGlvWithdrawalBuilder (ops/exchange/glv_withdrawal.rs)
│   Uses:                     → gmsol_store::execute_glv_withdrawal
│
├── execute_glv_shift()     → ExecuteGlvShiftBuilder (ops/exchange/glv_shift.rs)
│   Uses:                     → gmsol_store::execute_glv_shift
│
├── update_closed_state()   → UpdateClosedStateBuilder (ops/exchange/market_state.rs)
│   Uses:                     → gmsol_store::update_closed_state
│
└── update_fees_state()     → UpdateFeesStateBuilder (ops/exchange/market_state.rs)
    Uses:                     → gmsol_store::update_fees_state


Chain Monitoring  (crates/sdk/src/client/)
│
├── pubsub.rs               → PubsubClient::logs_subscribe()  [WebSocket]
├── accounts.rs             → getProgramAccounts() with filters  [HTTP polling]
└── pull_oracle.rs          → Fetch & verify oracle price reports
```

---

## Diagram 10 — On-Chain State Accounts the Keeper Reads/Writes

```
READ (Keeper inspects these to decide what to do):
┌────────────────────────────────────────────────────────────────┐
│  Store       [programs/store/src/states/store.rs]              │
│  └─ recent_time_window: u64  ← how long prices are valid       │
│  └─ claimable_time_key()     ← derives time key for claimable  │
│  └─ address.holding: Pubkey  ← where price impact diff goes    │
│                                                                │
│  Market      [programs/store/src/states/market/]               │
│  └─ meta: {index_token, long_token, short_token, market_token} │
│  └─ open_interest: {long, short}                               │
│  └─ is_adl_enabled: bool  ← Keeper checks this for ADL        │
│                                                                │
│  Order       [programs/store/src/states/order.rs]              │
│  └─ kind: OrderKind  ← what type of order                      │
│  └─ params: {trigger_price, acceptable_price, size, collateral}│
│  └─ swap: SwapActionParams  ← multi-hop swap path              │
│  └─ header.action_state  ← pending/completed/cancelled        │
│                                                                │
│  Position    [programs/store/src/states/position.rs]           │
│  └─ size_in_usd, collateral_amount, entry_price               │
│  └─ kind: {Long, Short}                                        │
│  └─ funding_fee_amount_per_size (for health calc)              │
│                                                                │
│  Glv         [programs/store/src/states/glv.rs]                │
│  └─ shift_last_executed_at: i64  ← for shift interval check   │
│  └─ shift_min_interval_secs: u32                               │
└────────────────────────────────────────────────────────────────┘

WRITTEN (Keeper's execution transaction mutates these):
┌────────────────────────────────────────────────────────────────┐
│  Oracle      [programs/store/src/states/oracle.rs]             │
│  └─ Temporary buffer, loaded with prices per transaction       │
│     (not persistent, cleared after each instruction)           │
│                                                                │
│  Market      ← pools updated, open_interest updated            │
│  Position    ← size/collateral updated (or account closed)     │
│  Order       ← marked completed or cancelled, then closed      │
│  Deposit     ← closed after execution                          │
│  Withdrawal  ← closed after execution                          │
│  UserHeader  ← GT rewards minted                               │
└────────────────────────────────────────────────────────────────┘
```

---

## Quick Reference: Keeper Decision Tree

```
New PDA detected on-chain
        │
        ├─ Is it an Order?
        │   ├─ kind = Market*          → Execute immediately (no price check needed)
        │   ├─ kind = Limit*/StopLoss  → Check trigger_price vs current price
        │   │                            If condition met → Execute
        │   │                            If not → Monitor, retry next price update
        │   ├─ kind = Liquidation      → (created internally, skip)
        │   └─ kind = AutoDeleveraging → (created internally, skip)
        │
        ├─ Is it a Deposit/Withdrawal?
        │   └─ Execute as soon as possible (no conditions)
        │
        ├─ Is it a GlvDeposit/GlvWithdrawal?
        │   └─ Execute as soon as possible
        │
        └─ Is it a Shift/GlvShift?
            └─ Check GLV.shift_last_executed_at + shift_min_interval_secs
               If interval passed AND shift_value > min_value → Execute

Continuous background scan:
  → All Position accounts → compute health → if unhealthy → liquidate queue
  → All Market accounts → check adl_enabled → if true → update_adl then ADL
```
