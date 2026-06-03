# Report ①: GMX-Solana Keeper Service: Architecture & Implementation Notes

I spent some time going through the `gmx-solana` repository and the GMX v2 docs to figure out how to structure the keeper. 

At first, I tried looking directly at the instruction handlers in `programs/store/src/instructions/` to see what a keeper actually calls, but that was confusing without understanding the high-level flow first. Here is a rough breakdown of how the protocol works, what the keeper needs to do, and the main pitfalls to watch out for.

---

## 1. The Core Architecture: Two-Step Async Execution

The most important thing to grasp is that **every user action on GMX-Solana is a two-step asynchronous process**. 

When a user wants to swap, open a position, deposit, or withdraw, they don't do it in one transaction. Instead:
1. **User Request:** The user submits a transaction that creates an on-chain "request" account (like an `Order`, `Deposit`, or `Withdrawal` PDA) and locks up their collateral.
2. **Keeper Execution:** The keeper detects this pending account, fetches fresh, signed oracle prices off-chain, and submits an "execution" transaction to settle the request.

This model is necessary because GMX-Solana uses a **pull-based oracle system** (Pyth, Chainlink, or Switchboard). Prices aren't constantly pushed on-chain. The keeper acts as the bridge—grabbing signed price reports off-chain and passing them into the execution transaction. The program then verifies that the prices are fresh (usually within a ~30-second window) before executing.

Without a working keeper, the protocol literally stops. Pending orders just sit in escrow, and users can't enter or exit positions.

---

## 2. What the Keeper Needs to Do (V1 vs. V2)

To get a minimal viable product running, we should focus on the critical paths first. 

### Priority V1 (Must-Haves)

*   **Order Execution:** 
    When an `Order` PDA is created, we need to execute it. In `execute_order.rs`, there are two main execution paths:
    *   `execute_increase_or_swap_order_v2` (for opening positions or swapping tokens).
    *   `execute_decrease_order_v2` (for closing or reducing positions).
    
    We need to handle different order types: `MarketIncrease`, `MarketDecrease`, `LimitIncrease`, `LimitDecrease`, `StopLossDecrease`, and `MarketSwap`/`LimitSwap`. For market orders, we execute immediately. For limit/stop orders, we monitor the price off-chain and only trigger execution when the price crosses the trigger threshold.

*   **Deposits and Withdrawals:** 
    When liquidity providers deposit into or withdraw from a GM pool, we need to execute these requests quickly to mint or burn GM tokens. There's no complex trigger price logic here, just speed, as delays ruin the LP experience.

*   **Liquidations:** 
    We must constantly poll all active `Position` accounts, calculate their health factor off-chain, and trigger a liquidation via the `position_cut` instruction if they fall below the maintenance margin.
    
    *Note on liquidations:* Looking at `position_cut.rs`, the keeper actually initializes an `Order` PDA *within* the liquidation transaction itself. There is a comment in the code warning that if escrow accounts are frozen, the instruction will fail. To avoid this, we have to bundle the escrow creation and the position cut instruction into the same transaction.

*   **ADL (Auto-Deleveraging):** 
    If a market's overall PnL exposure gets too high relative to its pool, we need to run ADL. This is a strict two-step process:
    1. Call `update_adl_state` to refresh the market's ADL flag using fresh prices.
    2. If ADL is enabled, select the most profitable positions and execute `auto_deleverage`.
    Trying to run step 2 without updating the state first will fail if the on-chain state is stale.

### Priority V2 (Can Defer)

*   **GLV Shift Execution:** 
    GLV (GMX Liquidity Vault) lets users deposit into a basket of markets. The keeper can trigger "shifts" to reallocate assets between pools. This is an optimization rather than a correctness issue, so we can defer it.
*   **Claimable Account Sweeping:** 
    When positions are closed, dust/fees sometimes go into claimable accounts. We can build a background worker to sweep these later.
*   **Multi-Keeper Consensus:** 
    To avoid multiple keepers racing and wasting transaction fees on the same liquidation or order, we will eventually need coordination (like a shared Redis lock or optimistic locking). For V1, we should stick to a single running instance to keep things simple.

---

## 3. Recommended Keeper Pipeline

Instead of a complex service, a simple event-driven pipeline is best:

```
[Watcher (WS + Polling)] 
       │
       ▼
[Priority Queue] (Liquidations > Market Orders > Deposits > Limit Orders)
       │
       ▼
[Price Fetcher] (Queries Pyth/Switchboard for all tokens in the route)
       │
       ▼
[Tx Builder] (Assembles remaining_accounts in exact positional order)
       │
       ▼
[Submitter] (Applies priority fees, sends tx, handles retries)
```

### Key pipeline design choices:
*   **WS + Polling Hybrid:** Solana WebSockets (`accountSubscribe`) are fast but drop under load. We should use WS for low-latency triggers, but run a fallback `getProgramAccounts` (GPA) poll every 15-30 seconds to catch any missed requests.
*   **Priority Queue:** Liquidations must be processed first to protect the protocol from bad debt. Market orders are next, while deposits and limit orders can tolerate slightly more latency.
*   **Address Lookup Tables (ALTs):** Solana's 1232-byte transaction limit is a major bottleneck because of the sheer number of accounts required for multi-hop swaps. The SDK (`crates/sdk/src/client/ops/alt.rs`) already has some ALT setup logic that we will need to use from day one.

---

## 4. The `remaining_accounts` Headache

The trickiest part of building the execution transaction is constructing the `remaining_accounts` slice. The on-chain program processes these accounts positionally, and getting the order wrong results in generic validation errors.

For an order execution, the accounts must be ordered exactly as follows:
1. **Price Feed Accounts:** One for each token in the swap path (derived via `swap.to_feeds(&token_map)`).
2. **Market Accounts:** The writable market accounts involved in the swap path.
3. **Virtual Inventory Accounts:** Writable virtual inventory accounts for those markets.

We should write a highly-typed builder module with thorough unit tests to handle this account resolution, rather than trying to construct the arrays ad-hoc in our main loop.

---

## 5. Major Technical Pitfalls

There are a few subtle areas in the codebase that are easy to get wrong:

### 1. The `claimable_time_key` Trap
When executing decrease orders, the program expects claimable accounts derived using a "time key":
```rust
&store.load()?.claimable_time_key(
    validated_recent_timestamp(store.load()?.deref(), recent_timestamp)?
)?,
```
The keeper passes `recent_timestamp` as an argument. If the transaction gets delayed in the Solana mempool for more than ~30 seconds, the timestamp expires, and the transaction fails. 

Even worse: if we retry with a *new* timestamp, it derives a *different* PDA address. If that PDA doesn't exist yet on-chain, our transaction will fail unless we also include instructions to initialize that new account (paying rent). The keeper needs explicit logic to handle this race condition under network congestion.

### 2. Off-Chain Health Checks
We have to calculate position health off-chain to know when to liquidate. Because the contract doesn't expose a simple `is_liquidatable` boolean, we have to replicate the on-chain math (including borrowing fees, funding fees, and price impact) in our keeper service. Any rounding discrepancies between our off-chain code and the program's math could lead to either missed liquidations (bad debt) or wasted transaction fees on failed liquidation attempts.

### 3. The `throw_on_execution_error` Flag
Both deposit and order execution instructions accept a `throw_on_execution_error` boolean. 
*   If set to `false`, errors during execution (like slippage exceeding `acceptable_price`) are handled gracefully: the order is canceled, collateral is returned, and the keeper still gets paid a fee.
*   If set to `true`, the entire transaction reverts, meaning the keeper receives no fee and the order remains pending.
We need to test this behavior carefully. For market orders, `false` is generally preferred so we can clean up failed orders. For limit orders, we might want `true` so the order isn't canceled just because of a brief price spike.

---

## 6. Recommended Step-by-Step Plan

If we want to get this running quickly, here is a logical progression:

1.  **Happy Path Execution:** Build a simple script that watches for a `Deposit` or `MarketIncrease` order, grabs the Pyth price feeds, and calls the execution instruction. Get this working end-to-end on devnet.
2.  **The Account Builder:** Write and unit-test the `remaining_accounts` resolution logic. This is the foundation of the keeper's reliability.
3.  **Basic Position Monitor:** Write a worker that pulls active positions, calculates their health using current oracle prices, and flags them for liquidation.
4.  **Robust Tx Submission:** Integrate priority fees, compute unit limits, and write retry logic to handle Solana network congestion.
5.  **Limit Orders & ADL:** Layer on the conditional trigger logic and the two-step ADL state updates.