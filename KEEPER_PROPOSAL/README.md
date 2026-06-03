# GMX-Solana Keeper Service — Design Proposal

**Task chosen:** Standard — Off-chain Keeper service for GMX-Solana

**Time spent:**
- Report ① (independent): ~9 hours
- Report ② (with AI): ~2 hours

**AI tools used in Report ②:** Claude (Anthropic)

---

## Files

- [`report-1-independent.md`](./report-1-independent.md) — Independent analysis, written without AI assistance
- [`report-2-ai-reflection.md`](./report-2-ai-reflection.md) — AI reflection: what changed, what didn't, and what AI missed

## Note

I chose the standard task because after reading the repo I think the Keeper problem
is genuinely the most interesting system design challenge here. There's a lot of nuance in
getting it right — especially around oracle timing, liquidation atomicity, and coordination
between multiple keeper instances — that I wanted to explore properly.
