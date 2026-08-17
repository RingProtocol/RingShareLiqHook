# RingShareLiqHook — Sepolia Deployment & Testing Guide

> This guide walks through deploying `RingShareLiqHook` on Sepolia (or an anvil fork) and verifying the JIT swap mechanism against the **current single-pool contract** in `src/hooks/RingShareLiqHook.sol`.

---

## Prerequisites

### 1. Dependencies

The repo uses git submodules for Foundry libraries (`forge-std`, `v4-core`, `v4-hooks-public`). Install them first:

```bash
git submodule update --init --recursive
forge build
```

### 2. Environment variables

Create a `.env` in the repo root (already covered by `.gitignore`):

```bash
# Sepolia RPC (or anvil fork URL)
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/<your-key>

# Deployer / owner private key (needs ETH for gas)
SEPOLIA_PRIVATE_KEY=0x...

# FewFactory address (already deployed on Sepolia)
FEW_FACTORY_ADDR=0x...

# Uniswap V4 PoolManager on Sepolia
POOL_MANAGER_ADDR=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543

# AllowlistedFactory used to deploy the hook (deploy your own if none exists)
ALLOWLISTED_FACTORY_ADDR=0x...

# Pair token addresses (ERC-20 on Sepolia)
TOKEN_A_ADDR=0x...
TOKEN_B_ADDR=0x...
```

### 3. fwTokens must exist

`FewFactory.getWrappedToken(TOKEN_A)` and `getWrappedToken(TOKEN_B)` must return non-zero addresses — `initializePool` reverts with `WrappedTokenNotFound` otherwise. If they do not exist yet, call `FewFactory.createToken(TOKEN_A_ADDR)` first.

### 4. Balance requirements

The owner needs enough of both tokens to cover the reserve (`bootstrap` + any later `deposit` calls), plus ETH for gas. fwTokens must be held (or minted via `wrap`) before calling `bootstrap`, which pulls fwToken0 and fwToken1 from the caller.

---

## Deployment

> The full workflow is scripted in `scripts/` (Foundry scripts, run with `forge script`).
> The steps below show both the scripted path and the underlying `cast` operations.

### Scripted workflow

```bash
source .env   # see "Environment variables" above

# 0. Deploy the AllowlistedFactory (once; allowlist is immutable per build)
forge script scripts/DeployAllowlistedFactory.s.sol:DeployAllowlistedFactory \
  --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
export ALLOWLISTED_FACTORY_ADDR=<printed address>

# 1. Deploy the hook via the factory (mines the CREATE2 salt for flags 0x2AC0)
forge script scripts/CreateHook.s.sol:CreateHook \
  --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
export HOOK_ADDR=<printed address>

# 2. Initialize the pool (created NOT live; LADDERED=true selects the 3-bucket ladder)
export TOKEN_A_ADDR=0x... TOKEN_B_ADDR=0x...
LADDERED=true forge script scripts/InitializePool.s.sol:InitializePool \
  --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv

# 3. Bootstrap: wrap -> approve -> seed reserve -> pool goes live (one-shot)
RESERVE_AMOUNT=10000000000000000000 \
  forge script scripts/Bootstrap.s.sol:Bootstrap \
  --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv

# 4. Owner operations afterwards (deposit / withdraw / setPoolLive / setDistribution / sweepClaims)
ACTION=setPoolLive LIVE=false \
  forge script scripts/Admin.s.sol:Admin \
  --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
```

Optional env vars: `FEE` (default 3000), `TICK_SPACING` (default 60), `SQRT_PRICE_X96`
(default 1:1), `OWNER` (default broadcaster), `MAX_GAS` (default 1000000), `SALT` / `SALT_START`,
`RESERVE_AMOUNT0` / `RESERVE_AMOUNT1`, `LADDERED`.

### What the scripts do on-chain

**Step 1 — Mine a CREATE2 salt for the hook flags.** `RingShareLiqHook.getHookPermissions()` requires the flags `0x2AC0` (`beforeInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, `afterSwap`). The hook is deployed through `AllowlistedFactory`, so deterministic addresses derive from the **factory's** address — `CreateHook` mines a salt against it such that the hook address has the `0x2AC0` bits set in its low 14 bits. `BaseHook`'s constructor validates the flags, so a wrong salt reverts instead of deploying a broken hook.

**Step 2 — Deploy via AllowlistedFactory.** `CreateHook` calls `AllowlistedFactory.deploy(creationCode, constructorArgs, salt)` with the `RingShareLiqHook` creation code (must match a creation-code hash on the factory's allowlist) and constructor arguments:

```
constructor(IPoolManager _pm, uint32 maxGas_, address owner_, IFewFactory _fewFactory)
```

Record the deployed hook address.

**Step 3 — Initialize the pool.** Equivalent `cast` call:

```bash
cast send $HOOK "initializePool((address,address,uint24,int24,address),(uint160,(int24,int24,uint16)[]))" \
  "($C0,$C1,3000,60,$HOOK)" \
  "($SQRT_PRICE_X96,[(-600,-180,2500),(-180,180,5000),(180,600,2500)])" \
  --rpc-url $RPC --private-key $PK
```

- `key.fee` must be a **static** fee — dynamic-fee pools revert with `DynamicFeeNotSupported`.
- Neither currency may be native ETH (`NativeNotSupported`); wrap as WETH.
- The pool is created **not live**: swaps revert with `PoolNotLive` until `bootstrap`.

**Step 4 — Bootstrap the reserve.** `Bootstrap` wraps any origin-token shortfall into fwTokens, approves the hook, and calls:

```bash
cast send $HOOK "bootstrap((address,address,uint24,int24,address),uint256,uint256)" \
  "($C0,$C1,3000,60,$HOOK)" $AMOUNT0 $AMOUNT1 \
  --rpc-url $RPC --private-key $PK
```

`bootstrap` pulls the fwTokens into the hook's reserve ledger and flips the pool to live. It is one-shot — a second call reverts with `PoolAlreadyBootstrapped`. Use `Admin` `ACTION=deposit` for later top-ups.

**Step 5 (optional) — Update the distribution later:**

```bash
cast send $HOOK "setDistribution((address,address,uint24,int24,address),(int24,int24,uint16)[])" \
  "($C0,$C1,3000,60,$HOOK)" "[(-600,-180,2500),(-180,180,5000),(180,600,2500)]" \
  --rpc-url $RPC --private-key $PK
```

Weights are in basis points and must sum to `10000`; ticks must align to the pool's `tickSpacing`. Reverts while a JIT cycle is in flight.

---

## Swap testing

Swaps can be routed through any V4-compatible router (e.g. a simple direct PoolManager swap router). Expected behavior:

| Scenario | Expected result |
|---|---|
| Normal swap, pool live, tick inside a bucket | Hook injects JIT liquidity in `beforeSwap`, swap executes against it, hook removes it in `afterSwap`; reserves shift in the direction of the trade |
| Reverse-direction swap | Same lifecycle; reserves shift the opposite way |
| Pool paused via `setPoolLive(key, false)` | Swap reverts with `PoolNotLive` — explicit failure for routers |
| Tick outside all buckets | `beforeSwap` returns `ZERO_DELTA` (no JIT); with no other liquidity in the pool, the swap fails on its own |
| Resume via `setPoolLive(key, true)` | JIT service resumes |

After each swap, verify:

1. **Reserves moved the right way.** `getReserves` returns fwToken + raw + claims per currency; a token0 → token1 swap increases reserve0 and decreases reserve1 (modulo fees).
2. **No lingering JIT state.** The JIT lock is transient and cleared in `afterSwap`; a following swap works normally.
3. **Claims handling.** If the hook was owed tokens it could not take, `claimReserveOf` holds ERC-6909 claims; they are redeemed automatically at the start of the next cycle or via `sweepClaims(key)`.

---

## Manual verification (cast)

### Compute the PoolId

```bash
POOL_ID=$(cast keccak $(cast abi-encode \
  "f((address,address,uint24,int24,address))" \
  "($C0,$C1,3000,60,$HOOK)"))
```

### Check hook state

```bash
# Reserves (fwToken + raw + claims per currency)
cast call $HOOK "getReserves((address,address,uint24,int24,address))(uint256,uint256)" \
  "($C0,$C1,3000,60,$HOOK)" --rpc-url $RPC

# Effective liquidity (equals getReserves for fwToken reserves)
cast call $HOOK "getEffectiveLiquidity((address,address,uint24,int24,address))(uint256,uint256)" \
  "($C0,$C1,3000,60,$HOOK)" --rpc-url $RPC

# Current distribution (keyed by PoolId)
cast call $HOOK "getDistribution(bytes32)((int24,int24,uint16)[])" $POOL_ID --rpc-url $RPC

# Indicative quote for a 0.1 token0 -> token1 swap (exact-in => negative amountSpecified)
cast call $HOOK "getIndicativeQuote((address,address,uint24,int24,address),bool,int256,bytes)(uint256)" \
  "($C0,$C1,3000,60,$HOOK)" true -100000000000000000 0x --rpc-url $RPC

# Pool state — PoolManager has no getSlot0 function; slot0 lives in the `_pools` mapping
# (storage slot 6) and is read via extsload. Word layout: sqrtPriceX96 (low 160 bits) |
# tick (bits 160-183, signed) | protocolFee (bits 184-207) | lpFee (bits 208-231)
SLOT0=$(cast keccak "${POOL_ID}0000000000000000000000000000000000000000000000000000000000000006")
cast call $POOL_MANAGER "extsload(bytes32)(bytes32)" $SLOT0 --rpc-url $RPC

# Owner (OZ Ownable2Step)
cast call $HOOK "owner()(address)" --rpc-url $RPC

# Deployment provenance
cast call $HOOK "factory()(address)" --rpc-url $RPC
```

### Owner operations

```bash
# Deposit more reserve (fwToken)
cast send $HOOK "deposit((address,address,uint24,int24,address),address,uint256)" \
  "($C0,$C1,3000,60,$HOOK)" $TOKEN_A $AMOUNT --rpc-url $RPC --private-key $PK

# Withdraw reserve
cast send $HOOK "withdraw((address,address,uint24,int24,address),address,uint256,address)" \
  "($C0,$C1,3000,60,$HOOK)" $TOKEN_A $AMOUNT $OWNER --rpc-url $RPC --private-key $PK

# Pause / resume JIT service
cast send $HOOK "setPoolLive((address,address,uint24,int24,address),bool)" \
  "($C0,$C1,3000,60,$HOOK)" false --rpc-url $RPC --private-key $PK

# Sweep outstanding ERC-6909 claims back into the reserve
cast send $HOOK "sweepClaims((address,address,uint24,int24,address))" \
  "($C0,$C1,3000,60,$HOOK)" --rpc-url $RPC --private-key $PK
```

---

## Historical notes (earlier codebase version)

The following issues applied to a previous revision of the codebase and are recorded for context; the fixes shipped in the deployed artifacts of that revision.

### `2^32` precision bug (fixed)

**Problem:** the repo's local `LiquidityAmounts` implementation mixed Q96 sqrt prices with a Q128 denominator, while `SqrtPriceMath.getAmount1Delta` computes in Q96. The round trip was therefore inflated by `2^32 = 4,294,967,296`.

**Impact:** allocation math computed a `need1` roughly 4.29 billion times the real requirement, so debt settlement always reverted `InsufficientReserve()`.

**Fix:** `src/libraries/LiquidityAmounts.sol` uses Q96 consistently and overflow-checks the `uint128` conversions:
- `getLiquidityForAmount1`: `L = amount1 * Q96 / (sqrtB - sqrtA)` (not Q128)
- `getLiquidityForAmount0`: `intermediate = sqrtA * sqrtB / Q96` (not Q128)

### SwapOperator settlement ordering (fixed)

**Problem:** V4's `sync()` snapshots the PoolManager's current balance. If a caller did not transfer and `settle()` immediately after `sync()`, the hook's internal `sync()`/`settle()` would overwrite that snapshot.

**Fix:** swap flows execute `sync → transfer → settle` consecutively (test scripts after the swap, the direct router before the swap), so no unsettled snapshot survives across hook calls.
