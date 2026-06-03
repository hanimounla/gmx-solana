# Report ②: AI Reflection

> After completing Report ①, I used Claude to review my analysis and look for gaps or improvements.
> This report covers what changed, what didn't, and where I think AI got things wrong.

---

## Part A: What AI helped me improve

### 1. The Address Lookup Table (ALT) point

I mentioned transaction size limits as a concern but didn't dig into it much. Claude pointed
out that the SDK already has an `alt.rs` module (`crates/sdk/src/client/ops/alt.rs`) that
handles ALT construction for exactly this reason. I knew ALTs existed on Solana but hadn't
connected the dots that the existing SDK already solves this problem — meaning any Keeper
built on top of the SDK gets this for free if it uses the `BundleBuilder` abstraction.

This is a genuine improvement to my design. Instead of treating "transaction size limits"
as a problem to solve from scratch, the correct approach is: use the SDK's `BundleBuilder`
which handles ALTs, and don't reinvent it.

I agree with this. It's a real improvement. The fact that the SDK exists and already handles
this concern changes the architectural picture — a Keeper should be built *on top of* the
existing SDK rather than rebuilding the transaction construction layer.

### 2. Separating concerns: oracle fetching vs. transaction execution

Claude suggested that oracle price fetching should be a completely separate async task from
the transaction builder and submitter — not something that happens inline when an order is
detected. The idea is a "price cache" that's continuously refreshed in the background, so
that when an order is ready to execute, prices are already available without a blocking fetch.

I think this is right and it's something I glossed over. My original design had the Keeper
fetch prices at execution time, which introduces latency and creates a failure mode where
a price fetch fails right when you need to execute a liquidation. A warm price cache with
background refresh is cleaner.

The caveat is that prices have a freshness requirement (~30 seconds). The cache needs to
be aware of this and flag stale entries rather than serving them blindly. But that's an
implementation detail, not a reason to reject the pattern.

I agree with this suggestion.

### 3. Structured logging and execution metrics

My report barely mentioned observability. Claude pushed me on this and specifically suggested
that each execution attempt should emit structured logs with: order pubkey, order kind, tokens
involved, prices used, success/failure, execution fee collected, and round-trip time.

This is correct and I should have emphasized it more. For a production Keeper, observability
is what lets you diagnose problems when a liquidation is missed or an order gets stuck.
Especially on a permissioned system where the Keeper is a trusted actor — the team running it
needs to know immediately when something goes wrong.

I agree with this.

---

## Part B: Where I think AI misled me

### 1. Suggesting event-driven architecture using message queues

Claude suggested using a message queue (something like Redis Streams or Kafka) as the primary
mechanism for passing detected orders from the watcher to the executor. The argument was that
this provides durability and decouples the components.

I think this is wrong for a V1 Keeper, and possibly wrong even for V2.

The problem is that GMX-Solana's pending actions already *live on-chain* in a durable way.
An Order PDA on Solana is the durable queue. The Keeper doesn't need a separate message
queue for durability — it just needs to be able to re-scan pending PDAs if it crashes. Adding
an external message queue means you now have two sources of truth (on-chain accounts and the queue)
that can drift apart if the Keeper crashes mid-processing. The queue says "execute order X" but
order X was already executed by a previous Keeper instance that died before acknowledging.

The correct durability model for a Solana Keeper is: treat the chain as the ground truth, always.
On startup, scan all pending PDAs. Use in-memory state only as a cache. If you crash and restart,
just re-scan.

A message queue adds operational overhead (another service to deploy and monitor) without adding
correctness guarantees you don't already get from the chain itself.

### 2. Recommending a separate "position health" microservice

AI suggested decomposing the Keeper into separate services: one for order execution, one for
monitoring position health, one for oracle price ingestion, each independently deployable.

The argument was scalability and separation of concerns. But this is premature for V1 and
possibly counterproductive even at scale.

The reason I push back: position health monitoring for liquidation purposes requires access
to oracle prices. If it's a separate service, you either duplicate the price ingestion logic,
or you add a dependency between services (the health monitor calls the oracle service). You've
now created a distributed system problem where you had a simple local computation problem.

More importantly, the health check math needs to be fast (you're scanning potentially thousands
of positions) and the result needs to immediately trigger a liquidation (you're racing against
the clock). Introducing inter-service latency and failure modes in that critical path is the
wrong trade-off.

I'd keep everything in a single process for V1. Use threads/async tasks for concurrency, not
separate services. If the Keeper ever gets to the scale where a single process can't keep up,
that's a good problem to have — and you'd shard it by market, not by function.

---

## Part C: Thinking AI can't do

### 1. Knowing that liquidation atomicity matters because of real token authority risks

The warning about frozen token accounts in `position_cut.rs` is something the protocol team
wrote because they had to think hard about what could go wrong in production. An engineer with
production experience in DeFi would immediately recognize this as a real risk — USDC's freeze
authority has been used before on real-world accounts, and on Solana this is a genuine vector.

AI can read that comment and explain what it says, but it doesn't have the intuition to weigh
this risk as "actually matters" versus "theoretical edge case." A senior DeFi engineer who has
seen a protocol get stuck because of frozen token accounts would recognize this immediately.
That's domain experience that shapes how you read the warning.

When I read that comment, I flagged it as important because I know from the GMX v1/v2 history
on EVM chains that edge cases in token transfer logic are exactly where protocols get stuck in
unexpected states. AI doesn't have that experience-shaped intuition.

### 2. Prioritizing what to build first under real time pressure

AI gave me a comprehensive list of everything the Keeper needs to do. It correctly identified
all the components. But when I asked "what should I build first if I have one week," it gave
me a prioritized list that treated GLV shift execution as roughly equivalent in urgency to
basic order execution.

That's wrong. An engineer who has seen a DeFi protocol go live knows that the first question
from operations is always "can we execute trades and can we liquidate?" Everything else is
secondary. GLV shifts being non-functional in week one is fine — missed liquidations on day one
are not. The prioritization instinct comes from having seen what matters when things go wrong.

### 3. Reading the "Known Issues" section with appropriate skepticism

The README has a section titled "Known Issues: Keepers." Claude read it and summarized it
accurately. But the judgment about which of those issues is *currently exploitable* in production
versus which is *theoretically possible but practically rare* requires understanding the economic
incentives of MEV on Solana specifically.

For example, the README notes that a malicious Keeper could profit by reordering order execution.
AI treated this as a high-severity concern. But on Solana, where block times are ~400ms and
the system is designed around fast finality, the practical window for this kind of manipulation
is much smaller than on Ethereum. The "trusted Keeper" model with economic disincentives
(the README mentions requiring many Keepers to make it unprofitable) is actually a reasonable
mitigation in this environment. An EVM-native engineer's intuitions about MEV don't transfer
cleanly to Solana without adjustment.

---

*AI reflection time: ~2 hours*
*Tool used: Claude (Anthropic)*
