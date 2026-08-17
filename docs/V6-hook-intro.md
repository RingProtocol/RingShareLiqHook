# Ring Share Liquidity Hook — Uniswap V4 Hook Introduction

## Overview

**Ring Share Liquidity Hook** (`RingShareLiqHook`) is a Uniswap V4 hook that provides **Just-In-Time (JIT) liquidity injection** for V4 pools. When a swap arrives, the hook temporarily deposits that pool's assigned reserves into concentrated-liquidity ranges, lets the swap execute against the injected depth, then immediately withdraws. This reduces the time capital sits in an active LP position and earns pool fees, but it does not eliminate adverse selection, inventory imbalance, or mark-to-market loss.

The hook integrates with the **Few Protocol** token wrapping system (`FewWrappedToken` / `FewFactory`), holding reserves as fwTokens and unwrapping them on-demand during each JIT cycle.

One hook contract can serve several pools, but capital is not globally pooled: every deposit is assigned to one `PoolId`, and Pool A cannot quote with or withdraw Pool B's reserve. “Share Liquidity” means the assigned FewToken reserve is shared with its corresponding V4 pool only for the duration of a swap.

## Hook Permissions

| Permission | Enabled | Purpose |
|---|---|---|
| `beforeInitialize` | Yes | Only admin can create pools attached to this hook |
| `beforeSwap` | Yes | JIT liquidity injection entry point |
| `afterSwap` | Yes | JIT liquidity removal + settlement |
| `beforeAddLiquidity` | No | Pool remains open to external LPs |
| `beforeRemoveLiquidity` | No | Pool remains open to external LPs |
| All others | No | — |

**Hook flags**: `0x20C0` (bit 13: `beforeInitialize`, bit 7: `beforeSwap`, bit 6: `afterSwap`)

The hook does **not** gate external liquidity. More external LP liquidity makes price manipulation more expensive, not cheaper, and provides a fallback when the hook declines to quote (disabled pool, out-of-range price, exhausted reserve).

## How It Works

### JIT Lifecycle

```
User swap arrives
       |
       v
  beforeSwap
       |
       +-- Gate checks: not paused, pool enabled, distribution configured,
       |   current tick inside a configured bucket
       |
       +-- If any gate fails --> return ZERO_DELTA (swap proceeds against pool's own liquidity)
       |
       +-- Enter per-pool transient JIT lock
       |
       +-- Redeem ERC-6909 claims from previous cycles (cheapest capital first)
       +-- Unwrap fwToken --> raw token (only the shortfall needed)
       +-- modifyLiquidity: inject raw tokens into configured tick ranges
       +-- Settle debt with PoolManager (hook delta back to zero)
       +-- Return ZERO_DELTA
       |
       v
  V4 AMM executes swap against injected + existing liquidity
       |
       v
  afterSwap
       |
       +-- Remove all JIT positions (modifyLiquidity with negative delta)
       +-- Resolve net delta:
       |     - Positive (hook is owed) --> mint ERC-6909 claims
       |     - Negative (hook owes)    --> settle from raw reserve
       +-- Wrap leftover raw tokens back into fwToken
       +-- Clear JIT lock
       |
       v
  Swap complete
```

### Key Design Decisions

**1. Reserve is the only risk limit.**

Each JIT cycle deploys the pool's entire reserve. There is no per-swap cap or rate limiter — neither protects against the loss that actually matters (an arbitrageur picking off a stale quote needs one swap), and a per-block budget would let a dust swap burn the budget and deny service to everyone. Fund each pool with only what may be lost.

**2. One enabled pool per currency pair.**

Two enabled pools on the same pair would create an arbitrage the hook funds: each pool prices its JIT liquidity off its own tick, so once ticks diverge a swapper buys from the cheap pool and sells to the expensive one — both legs filled from the hook's reserves. This is enforced at the contract level via `enabledPoolForPair`.

**3. Laddered distribution for self-healing.**

A single all-covering tick range (e.g. `[-600, 600]`) stops quoting when either side of the reserve runs dry, because `getLiquidityForAmounts` takes the minimum of both sides for in-range buckets. A **laddered** distribution with adjacent non-overlapping ranges (e.g. `[-600,-180] / [-180,180] / [180,600]`) keeps the pool alive: buckets entirely above the current price are funded by currency0 alone, and those below by currency1 alone, so an exhausted side still leaves the opposite rungs quoting — and those rungs buy the exhausted currency back through ordinary flow.

**4. No opportunistic `take`.**

When the hook is owed tokens (positive delta), it always mints ERC-6909 claims rather than taking real ERC-20 from the PoolManager. Taking real balance can consume tokens that other in-flight flows still need. Claims are redeemed at the start of the next JIT cycle, or manually via `sweepClaims`.

**5. Transient storage for JIT state.**

All per-cycle state (JIT lock, active liquidity per bucket) uses EIP-1153 transient storage — zero gas cost outside the transaction, no stale state between cycles. A global in-flight counter ensures at most one JIT cycle is open across all pools at any time, making delta attribution unambiguous.

## Security Properties

- **Declined JIT service is non-blocking.** A disabled pool, out-of-range price, or unusable reserve makes `beforeSwap` return `ZERO_DELTA`, so the swap may continue against the pool's own liquidity. Once a JIT cycle has started, an unwrap, PoolManager settlement, liquidity modification, or wrap failure reverts the entire swap atomically; the hook does not promise that it can never cause a revert.
- **Admin-only pool creation.** `_beforeInitialize` rejects pool initialization from non-admin addresses, preventing third parties from attaching pools to the hook without configured reserves.
- **Two-step admin transfer.** `transferAdmin` nominates; `acceptAdmin` confirms. A mistyped address cannot lock the reserves.
- **Per-pool reserve isolation.** Each pool's reserves are tracked in separate ledgers (`fwReserveOf` / `rawReserveOf` / `claimReserveOf`), keyed by `PoolId`. Pool A can never withdraw or deploy pool B's capital.
- **Cross-pool reentrancy guard.** Transient per-pool locks + global in-flight counter. The fwToken `wrap`/`unwrap` external calls are reentrancy vectors; the guard ensures a nested cycle cannot settle another pool's in-flight delta.
- **Price manipulation guard.** The hook only intervenes when the current tick falls inside a configured bucket. If the price has been pushed outside all buckets, the hook stays out entirely.
- **Emergency controls.** `disablePool(key)` stops a single pool immediately (not gated on JIT-not-in-progress, so it always works). `setPaused(true)` is a global kill switch. Neither blocks swaps, LP exits, or withdrawals.

## Sepolia Verification

| Component | Address |
|---|---|
| PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| FewFactory | `0x226e65279E177A779522864Ce1dE40c85E2C08A5` |
| RingShareLiqHook | `0x777c0526e3C0500e27103dc7AA076C5e2FB7A0c0` |
| PoolOperator | `0x048e19d64F17AE3871A3FeEF34F9710E92ECf6a5` |
| V4DirectSwapRouter | `0xc14Cc10f5996410e412a50c0753871b10e1F62Aa` |

The previously documented hook address had no deployed bytecode and has been removed. The deployment above completed an initialized pool, bootstrap LP exit/restore proof, configured reserves, and a successful real-router swap. See [V6-sepolia.md](./V6-sepolia.md) for transaction hashes, resulting state, independent RPC checks, and remaining limitations.

## Source Code

- Hook contract: `src/hooks/RingShareLiqHook.sol`
- Base (admin + pause): `src/base/OwnedHook.sol`
- Deployment script: `script/DeployRingShareLiqSepolia.s.sol`
- Tests: `test/RingShareLiqHook.t.sol`

## License

MIT
