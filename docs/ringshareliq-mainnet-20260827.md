# RingShareLiqHook — Mainnet Deployment Record (2026-08-27)

> Partial mainnet deployment: `AllowlistedFactory` deployed and verified. Hook deployment,
> pool initialization, and bootstrap are pending — the deployer needs more ETH and WETH/WBTC
> tokens to complete the remaining steps. This is a testnet-to-mainnet progression record.

## Status

| Step | Status |
|---|---|
| Deploy AllowlistedFactory | ✅ Complete |
| Deploy RingShareLiqHook via factory | ⏳ Pending (need ~0.05 ETH for gas) |
| Initialize pool (WBTC/WETH) | ⏳ Pending |
| Bootstrap reserves | ⏳ Pending (need WETH + WBTC) |
| Verify source on Etherscan | ⏳ Pending |

## Deployment snapshot

| Item | Value |
|---|---|
| Chain ID | `1` (Ethereum mainnet) |
| Deployer / hook owner | `0x87555dd0e101817c1bc7867e32451b080C55f596` |
| Compiler | solc `0.8.26`, EVM Cancun, via-IR, optimizer runs `1` |
| Allowed creation code hash | `0xd88bdab32efd4bc3e4c925fd0b7ba82f449ecca56f0d93584a02b5af8ee93552` |
| Gas price | 0.32 gwei (low-fee window) |
| Gas used (factory deploy) | 339,759 |
| Cost | ~0.000142 ETH |

## Contract addresses

| Component | Address |
|---|---|
| Uniswap V4 PoolManager (canonical mainnet) | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| StateView (canonical mainnet) | `0x7ffe42c4a5deea5b0fec41c94c136cf115597227` |
| FewFactory (mainnet) | `0x7D86394139bf1122E82FDF45Bb4e3b038A4464DD` |
| **AllowlistedFactory (new)** | `0x92FF2E6C0a105d26677236e17aee6EAE5Da31ce5` |
| RingShareLiqHook | _pending_ |
| Swap router (PoolSwapTest) | _pending_ |

## Planned pool configuration

| Item | Value |
|---|---|
| currency0 | `WBTC` — `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` (8 decimals) |
| currency1 | `WETH` — `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (18 decimals) |
| fwToken0 (wrapped WBTC) | `0x2078f336Fdd260f708BEc4a20c82b063274E1b23` |
| fwToken1 (wrapped WETH) | `0xa250CC729Bb3323e7933022a67B52200fE354767` |
| Pool fee | `3000` (0.3%) |
| Tick spacing | `60` |
| Distribution | `[-600,-180] 25%` / `[-180,180] 50%` / `[180,600] 25%` (laddered) |
| Initial price | _TBD_ (WBTC/WETH price at init time) |

> Note: `WBTC < WETH` numerically, so `currency0 = WBTC`, `currency1 = WETH`.
> FewFactory wrapper mappings verified: `getWrappedToken(WBTC) = 0x2078…1b23`,
> `getWrappedToken(WETH) = 0xa250…4767`, and both wrappers' `token()` return the correct underlying.

## Key transactions

| Action | Mainnet transaction | Block |
|---|---|---|
| Deploy AllowlistedFactory | [`0x63bdbb…e1f6`](https://etherscan.io/tx/0x63bdbbec90612090fd338a5b083e95493ee6be3872ac8d08fa8d92b9d312e1f6) | `0x18a6106` (`25,753,798`) |

## Remaining steps (to be executed once funded)

```bash
# .env must define: MAINNET_RPC_URL, MAINNET_PRIVATE_KEY,
# POOL_MANAGER_MAINNET, FEW_FACTORY_MAINNET,
# WBTC_TOKEN_A, WETH_TOKEN_B, FEW_WBTC_TOKEN_A, FEW_WETH_TOKEN_B
export POOL_MANAGER_ADDR=$POOL_MANAGER_MAINNET
export ALLOWLISTED_FACTORY_ADDR=0x92FF2E6C0a105d26677236e17aee6EAE5Da31ce5

# 2. Deploy hook via factory (mines CREATE2 salt for 0x2AC0 flags)
forge script scripts/CreateHook.s.sol:CreateHook \
  --rpc-url $MAINNET_RPC_URL --private-key $MAINNET_PRIVATE_KEY --broadcast -vv --slow
export HOOK_ADDR=<deployed hook address>

# 3. Initialize pool (laddered distribution, set SQRT_PRICE_X96 to current WBTC/WETH price)
export TOKEN_A_ADDR=$WBTC_TOKEN_A
export TOKEN_B_ADDR=$WETH_TOKEN_B
export LADDERED=true
export SQRT_PRICE_X96=<sqrt price for WBTC/WETH>
forge script scripts/InitializePool.s.sol:InitializePool \
  --rpc-url $MAINNET_RPC_URL --private-key $MAINNET_PRIVATE_KEY --broadcast -vv --slow

# 4. Bootstrap reserves (wraps origin tokens -> fwTokens automatically)
export RESERVE_AMOUNT0=<WBTC amount in raw units (8 decimals)>
export RESERVE_AMOUNT1=<WETH amount in raw units (18 decimals)>
forge script scripts/Bootstrap.s.sol:Bootstrap \
  --rpc-url $MAINNET_RPC_URL --private-key $MAINNET_PRIVATE_KEY --broadcast -vv --slow

# 5. Verify source on Etherscan
forge verify-contract --chain-id 1 --verifier etherscan \
  --verifier-url "https://api.etherscan.io/api" --compiler-version v0.8.26 \
  --constructor-args "$(cast abi-encode 'f(bytes32[])' '[0xd88bdab32efd4bc3e4c925fd0b7ba82f449ecca56f0d93584a02b5af8ee93552]')" \
  --watch 0x92FF2E6C0a105d26677236e17aee6EAE5Da31ce5 \
  src/factory/AllowlistedFactory.sol:AllowlistedFactory
```

## Funding requirements to complete

| Need | Amount | Purpose |
|---|---|---|
| ETH for gas | ~0.05 ETH | Hook deploy + init + bootstrap (~5.2M gas at ~10 gwei) |
| WBTC | TBD | Reserve currency0 (bootstrap amount) |
| WETH | TBD | Reserve currency1 (bootstrap amount) |

Deployer balance after factory deploy: `0.00995 ETH` — insufficient for remaining steps.
