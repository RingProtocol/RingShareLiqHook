# Ring Share Liquidity Hook — Uniswap V4 Hook Introduction

## Overview

**Ring Share Liquidity Hook** (`RingShareLiqHook`) is a Uniswap V4 hook that provides **RingV2 constant-product swap** pricing for a V4 pool. When a swap arrives, the hook intercepts it via `beforeSwapReturnDelta` and prices it against its own fwToken reserves using a V2-style `x*y=k` formula. The V4 pool's native AMM never executes the swap — the hook is the sole liquidity source.

The hook integrates with the **Few Protocol** token wrapping system (`FewWrappedToken` / `FewFactory`), holding reserves as fwTokens. **RingV2** is a V2 variant where the underlying ("origin") tokens are wrapped into fwTokens; the V2 reserves are the hook's fwToken balances, and swaps change them in place.

**One hook per pool.** Each hook instance is deployed through the `AllowlistedFactory` and serves exactly one pool, configured via `initializePool` + `bootstrap`. `initializePool` permanently binds `configuredPoolId`; every owner, callback, execution, and quote path rejects a different `PoolKey`. The hook's `currencyDelta` is therefore always this pool's delta, and the reserve ledgers track only this pool's capital.

**Owner-owned capital.** The owner is the sole capital provider: reserves are funded via `bootstrap` / `deposit` and withdrawn via `withdraw`. There is no share accounting and no external LP entry point — external `modifyLiquidity` calls are rejected, so the pool's only liquidity is the hook's V2 reserve. "Adding liquidity is what you deposit is what you get" — deposited fwToken amounts become the reserves directly, with no tick distribution or pro-rata scaling.

## Hook Permissions

| Permission | Enabled | Purpose |
|---|---|---|
| `beforeInitialize` | Yes | Block direct `PoolManager.initialize`; pools must be created through `initializePool` |
| `beforeAddLiquidity` | Yes | Allow external LP additions (hook intercepts swaps, so external LP liquidity is never used) |
| `beforeRemoveLiquidity` | Yes | Allow external LP removals |
| `beforeSwap` | Yes | V2 swap computation and interception |
| `afterSwap` | Yes | V2 swap settlement (unwrap output, mint claims for input) |
| `beforeSwapReturnDelta` | Yes | The hook answers the swap with its own delta; the AMM swaps zero |
| All others | No | — |

**Hook flags**: `0x2AC8` (bit 13: `beforeInitialize`, bit 11: `beforeAddLiquidity`, bit 9: `beforeRemoveLiquidity`, bit 7: `beforeSwap`, bit 6: `afterSwap`, bit 3: `beforeSwapReturnDelta`)

External liquidity is allowed: external LPs may add and remove V4 positions freely via `modifyLiquidity`. However, since the hook intercepts all swaps via `beforeSwapReturnDelta`, external LP liquidity is never used for swap execution — the hook's V2 fwToken reserve is the sole swap source. External LPs earn no swap fees.

## How It Works

### Swap Lifecycle

```
User swap arrives
       |
       v
  beforeSwap
       |
       +-- Gate checks: pool live, valid
       |
       +-- Pool not live --> revert PoolNotLive
       +-- Zero reserves --> revert InsufficientReserve
       |
       +-- Redeem ERC-6909 claims from previous swaps (cheapest capital first)
       +-- Wrap raw reserves back into fwToken
       +-- Read V2 reserves, compute amountIn / amountOut via constant-product math
       +-- Store swap context in transient storage
       +-- Return BeforeSwapDelta (AMM swaps zero)
       |
       v
  V4 AMM executes zero-size swap (no-op)
       |
       v
  afterSwap
       |
       +-- Read swap context from transient storage
       +-- Unwrap fwToken for output currency, settle to PoolManager
       +-- Mint ERC-6909 claims for input currency (swapper hasn't settled yet)
       +-- Wrap leftover raw balance back into fwToken
       +-- Clear swap context
       |
       v
  Swap complete
```

### V2 Pricing Formula

The hook uses a V2-style constant-product formula with v4 fee units (pips, `1e6 = 100%`):

- **Exact input** (`amountSpecified < 0`):
  `amountOut = (amountIn * (1e6 - fee) * reserveOut) / (reserveIn * 1e6 + amountIn * (1e6 - fee))`

- **Exact output** (`amountSpecified > 0`):
  `amountIn = (reserveIn * amountOut * 1e6) / ((reserveOut - amountOut) * (1e6 - fee)) + 1`

The fee is the pool's static LP fee (`key.fee`), so a v4 fee of `3000` (0.3%) maps directly. Dynamic-fee pools are rejected at initialization.

### Key Design Decisions

**1. `beforeSwapReturnDelta` intercepts the swap.**

The hook returns a `BeforeSwapDelta` that fully accounts for the swap's input and output. The PoolManager applies this delta to the hook and charges the remaining (zero) swap to the native AMM, so the V4 pool's own liquidity never executes the user's swap. The hook is the sole liquidity source.

**2. One hook per pool, deployed by an allowlisted factory.**

Each hook instance serves exactly one `configuredPoolId` and is deployed through `AllowlistedFactory`, a CREATE2 deployer restricted to an immutable allowlist of creation-code hashes. Aggregators and routers can verify a hook's provenance via its `factory()` getter, and deterministic addressing lets the required flag bits (`0x2AC8`) be salt-mined against the factory address.

**3. Direct reserve model — no LP shares.**

The owner deposits fwTokens and those amounts become the reserves. There is no tick allocation, no pro-rata scaling, and no share token. `deposit` and `withdraw` move fwTokens between the owner and the pool's reserve ledger 1:1.

**4. No opportunistic `take`.**

When the hook is owed tokens (positive delta from swap input), it mints ERC-6909 claims rather than taking real ERC-20 from the PoolManager — at that point in the swap the PoolManager does not yet hold the swapper's input. Claims are redeemed at the start of the next swap, or manually via `sweepClaims`.

**5. Transient storage for swap context.**

The per-swap context (amountIn, amountOut, zeroForOne) uses EIP-1153 transient storage — zero storage cost outside the transaction, no stale state between swaps.

## Owner API

| Function | Purpose |
|---|---|
| `initializePool(key, sqrtPriceX96)` | Create the pool with initial price (not live yet) |
| `bootstrap(key, amount0, amount1)` | Seed fwToken reserves and flip the pool to live (one-shot) |
| `deposit(key, amount0, amount1)` | Add fwToken to the pool's reserve |
| `withdraw(key, amount0, amount1, to)` | Withdraw fwToken reserve |
| `setPoolLive(key, live)` | Pause / resume the pool's swap service |
| `sweepClaims(key)` | Redeem outstanding ERC-6909 claims back into the reserve |

Ownership uses OpenZeppelin `Ownable2Step` (via `OwnedALFHook`): `transferOwnership` nominates, `acceptOwnership` confirms, so a mistyped address cannot lock the reserves.

View functions for routers and aggregators (ALF interface): `getReserves`, `getEffectiveLiquidity`, `getIndicativeQuote`, `swapToPrice`. `getReserves` reports the accounting total (fw + raw + claims). `getEffectiveLiquidity` caps ERC-6909 claims at the PoolManager balance that can be redeemed synchronously. Quotes use the same V2 formula and fee as actual swap execution; they return zero if the pool is paused or the swap cannot be filled.

## Security Properties

- **Explicit failure modes.** A pool that has not been bootstrapped (or was paused via `setPoolLive`) makes `beforeSwap` revert with `PoolNotLive`. A live pool with zero reserves reverts with `InsufficientReserve` before the PoolManager can mutate price.
- **Owner-gated pool creation.** `initializePool` is `onlyOwner`; direct `PoolManager.initialize` on a pool referencing this hook is rejected by `beforeInitialize`, so no third party can attach pools to the hook.
- **External LP allowed but inert.** External `modifyLiquidity` is allowed, but since the hook intercepts all swaps via `beforeSwapReturnDelta`, external LP liquidity is never used for swap execution. External LPs earn no swap fees and can remove their positions freely.
- **Reserve ledger isolation.** `fwReserveOf` / `rawReserveOf` / `claimReserveOf` are the source of truth for sizing, settlement and withdrawal; the physical token balance is only a defensive cap. `withdraw` debits the ledger before transferring, so the reserve can never be overdrawn.
- **Reentrancy guards.** OpenZeppelin `ReentrancyGuardTransient` on owner functions. The fwToken `wrap`/`unwrap` external calls are reentrancy vectors; a nested swap cannot settle an in-flight delta.
- **Input validation.** Native ETH (`address(0)`) is supported only as `currency0`; `currency1` must be an ERC-20. Dynamic-fee pools are rejected. The FewFactory must have a registered fwToken for each underlying currency before initialization.
