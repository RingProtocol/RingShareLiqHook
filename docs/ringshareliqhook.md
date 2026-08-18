# Ring Share Liquidity Hook — Uniswap V4 Hook Introduction

## Overview

**Ring Share Liquidity Hook** (`RingShareLiqHook`) is a Uniswap V4 hook that provides **Just-In-Time (JIT) liquidity injection** for a V4 pool. When a swap arrives, the hook temporarily deploys the pool's reserve into concentrated-liquidity ranges, lets the swap execute against the injected depth, then immediately withdraws. This reduces the time capital sits in an active LP position while earning pool fees, but it does not eliminate adverse selection, inventory imbalance, or mark-to-market loss.

The hook integrates with the **Few Protocol** token wrapping system (`FewWrappedToken` / `FewFactory`), holding reserves as fwTokens and unwrapping them on demand during each JIT cycle.

**One hook per pool.** Each hook instance is deployed through the `AllowlistedFactory` and serves exactly one pool, configured via `initializePool` + `bootstrap`. `initializePool` permanently binds `configuredPoolId`; every owner, callback, execution, and quote path rejects a different `PoolKey`. The hook's `currencyDelta` is therefore always this pool's delta, and the reserve ledgers track only this pool's capital. "Share Liquidity" means the pool's FewToken reserve is shared with its V4 pool only for the duration of a swap.

**Owner-owned capital.** The owner is the sole capital provider: reserves are funded via `bootstrap` / `deposit` and withdrawn via `withdraw`. There is no share accounting and no external LP entry point — external `modifyLiquidity` calls are rejected, so the pool's only liquidity is the hook's JIT liquidity.

## Hook Permissions

| Permission | Enabled | Purpose |
|---|---|---|
| `beforeInitialize` | Yes | Block direct `PoolManager.initialize`; pools must be created through `initializePool` |
| `beforeAddLiquidity` | Yes | Reject external LP additions (`LiquidityNotAllowed`) |
| `beforeRemoveLiquidity` | Yes | Reject external LP removals (`LiquidityNotAllowed`) |
| `beforeSwap` | Yes | JIT liquidity injection entry point |
| `afterSwap` | Yes | JIT liquidity removal + delta settlement |
| All others | No | — |

**Hook flags**: `0x2AC0` (bit 13: `beforeInitialize`, bit 11: `beforeAddLiquidity`, bit 9: `beforeRemoveLiquidity`, bit 7: `beforeSwap`, bit 6: `afterSwap`)

External liquidity is blocked by design: the pool's depth comes entirely from the JIT reserve. `bootstrap`, resume, and every `beforeSwap` prove that the current reserves can deploy non-zero active liquidity. Otherwise the call reverts with `NoActiveLiquidity`; an empty pool can never execute a zero-balance swap or move its price for free.

## How It Works

### JIT Lifecycle

```
User swap arrives
       |
       v
  beforeSwap
       |
       +-- Gate checks: pool live, distribution configured,
       |   current tick inside a configured bucket
       |
       +-- Pool not live --> revert PoolNotLive (explicit failure for routers)
       +-- No active JIT liquidity --> revert NoActiveLiquidity
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
  V4 AMM executes swap against injected liquidity
       |
       v
  afterSwap
       |
       +-- Remove all JIT positions (modifyLiquidity with negative delta)
       +-- Resolve net delta per currency:
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

**2. One hook per pool, deployed by an allowlisted factory.**

Each hook instance serves exactly one `configuredPoolId` and is deployed through `AllowlistedFactory`, a CREATE2 deployer restricted to an immutable allowlist of creation-code hashes. Aggregators and routers can verify a hook's provenance via its `factory()` getter, and deterministic addressing lets the required flag bits (`0x2AC0`) be salt-mined against the factory address. The contract enforces the single-pool boundary on every state-changing, callback, and quote path.

**3. Laddered distribution for self-healing.**

A single all-covering tick range (e.g. `[-600, 600]`) stops quoting when either side of the reserve runs dry, because `getLiquidityForAmounts` takes the minimum of both sides for in-range buckets. A **laddered** distribution with adjacent non-overlapping ranges (e.g. `[-600,-180] / [-180,180] / [180,600]`) keeps the pool alive: buckets entirely above the current price are funded by currency0 alone, and those below by currency1 alone, so an exhausted side still leaves the opposite rungs quoting — and those rungs buy the exhausted currency back through ordinary flow.

**4. No opportunistic `take`.**

When the hook is owed tokens (positive delta), it always mints ERC-6909 claims rather than taking real ERC-20 from the PoolManager — at that point in the swap the PoolManager does not yet hold the swapper's input. Claims are redeemed at the start of the next JIT cycle, or manually via `sweepClaims`.

**5. Transient storage for JIT state.**

All per-cycle state (JIT lock, active liquidity per bucket) uses EIP-1153 transient storage — zero storage cost outside the transaction, no stale state between cycles. `JITLock.enter` checks both its per-pool slot and a global in-flight slot, so a token callback cannot start another JIT cycle before the first one settles.

## Owner API

| Function | Purpose |
|---|---|
| `initializePool(key, config)` | Create the pool with initial price and distribution (not live yet) |
| `bootstrap(key, amount0, amount1)` | Seed fwToken reserves and flip the pool to live (one-shot) |
| `deposit(key, currency, amount)` | Add fwToken to the pool's reserve |
| `withdraw(key, currency, amount, to)` | Withdraw fwToken reserve |
| `setDistribution(key, buckets)` | Replace tick ranges / weights (weights sum to 10,000) |
| `setPoolLive(key, live)` | Pause / resume the pool's JIT service |
| `sweepClaims(key)` | Redeem outstanding ERC-6909 claims back into the reserve |

Ownership uses OpenZeppelin `Ownable2Step` (via `OwnedALFHook`): `transferOwnership` nominates, `acceptOwnership` confirms, so a mistyped address cannot lock the reserves. Every configuration and fund-movement entry point reverts while a JIT cycle is in flight.

View functions for routers and aggregators (ALF interface): `getReserves`, `getEffectiveLiquidity`, `getIndicativeQuote`, `swapToPrice`, `getDistribution`. `getReserves` reports the accounting total. `getEffectiveLiquidity` caps ERC-6909 claims at the PoolManager balance that can be redeemed synchronously. Quotes use that effective amount and return zero if filling the request would cross a distribution boundary; they are conservative discovery hints, not execution guarantees.

## Security Properties

- **Explicit failure modes.** A pool that has not been bootstrapped (or was paused via `setPoolLive`) makes `beforeSwap` revert with `PoolNotLive`. A live pool whose current reserves cannot deploy non-zero in-range JIT liquidity reverts with `NoActiveLiquidity` before the PoolManager can mutate price.
- **Owner-gated pool creation.** `initializePool` is `onlyOwner`; direct `PoolManager.initialize` on a pool referencing this hook is rejected by `beforeInitialize`, so no third party can attach pools to the hook.
- **Hook-only liquidity.** External `modifyLiquidity` always reverts, so no third party can add positions that the hook's accounting does not know about. (v4-core's `noSelfCall` skips the hook callback for the hook's own calls, so the JIT path is unaffected.)
- **Reserve ledger isolation.** `fwReserveOf` / `rawReserveOf` / `claimReserveOf` are the source of truth for sizing, settlement and withdrawal; the physical token balance is only a defensive cap. `withdraw` debits the ledger before transferring, so the reserve can never be overdrawn.
- **Reentrancy guards.** The transient `JITLock` plus OpenZeppelin `ReentrancyGuardTransient` on owner functions. The fwToken `wrap`/`unwrap` external calls are reentrancy vectors; a nested cycle cannot settle an in-flight delta.
- **Price manipulation guard.** If the current tick falls outside every configured bucket, active JIT liquidity is zero and `beforeSwap` reverts before the pool price can move.
- **Input validation.** Native ETH (`address(0)`) currencies and dynamic-fee pools are rejected at `initializePool`; both currencies must have fwTokens registered in the FewFactory, and each wrapper's `token()` must match its underlying. The validated wrapper addresses are fixed for the life of the hook, so a later factory mapping change cannot redirect deposits, withdrawals, wrap, or unwrap.
- **Emergency control.** `setPoolLive(key, false)` stops the pool's JIT service immediately. It never blocks withdrawals — pausing withholds the hook's own capital, it does not trap anyone else's.

## Limitations

- Native ETH is not supported; wrap as WETH (or the chain's wrapped native token) first.
- Dynamic-fee pools are not supported.
- There is no fallback liquidity: when the hook does not quote, the pool has no depth.
- Indicative quotes intentionally return zero when a request would cross a configured bucket boundary. Routers must obtain an execution quote or split the request rather than extrapolate one liquidity segment across the full distribution.
- The current source has not completed an independent audit, is not deployed, and is not verified in Uniswap production routing.

## Source Code

- Hook contract: `src/hooks/RingShareLiqHook.sol`
- Deployment factory: `src/factory/AllowlistedFactory.sol`
- Base hook utilities: `src/utils/BaseHook.sol`, `src/base/`
- ALF base (`OwnedALFHook`, `Distribution`, `JITLock`): vendored from Uniswap's `v4-hooks-public` into `src/alf/`
- Deployment and operations scripts: `scripts/`
- Tests: `test/RingShareLiqHook.t.sol`

## License

MIT
