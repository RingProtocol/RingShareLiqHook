# RingShareLiqHook — Sepolia Deployment Record (2026-08-26)

> End-to-end deployment and acceptance run of the current `RingShareLiqHook` build on Ethereum
> Sepolia, using a freshly deployed `AllowlistedFactory` and the canonical Uniswap V4 `PoolManager`.
> This is a testnet technical acceptance only — not a security audit or production readiness claim.

## Conclusion

On 2026-08-26, the current `RingShareLiqHook` build completed an end-to-end run on Ethereum Sepolia
with pre-existing test tokens (`SUNI`/`SDAI`): new `AllowlistedFactory` deployment, CREATE2 hook
deployment with salt-mined permission flags (`0x2AC0`), pool initialization with a laddered
distribution, bootstrap of reserves (10 ether per side via the real `FewFactory` wrappers), and
swaps in both directions through a `PoolSwapTest` router. All transactions succeeded and the
resulting state was re-read via `cast`.

## Deployment snapshot

| Item | Value |
|---|---|
| Chain ID | `11155111` |
| Run block range | `11570344` – `11570362` |
| Deployer / hook owner | `0x87555dd0e101817c1bc7867e32451b080C55f596` |
| Compiler | solc `0.8.26` (Sepolia profile), EVM Cancun, via-IR, optimizer runs `1` |
| Hook flags | `0x2AC0` (`beforeInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, `afterSwap`) |
| Hook runtime code hash | `0xf954147e06973c5fc69e860c56f628cf837d32e29ece809b1e94e9df9b342a8d` |
| Allowed creation code hash | `0xd88bdab32efd4bc3e4c925fd0b7ba82f449ecca56f0d93584a02b5af8ee93552` |
| CREATE2 salt | `0x00000000000000000000000000000000000000000000000000000000000030a7` (12455 iterations) |
| PoolId | `0xcb8470b9bec22ea29a373a8e3c8ab6de72a27d8387a75bb1edb84e3b16076421` |
| Pool fee / tickSpacing | `3000` / `60` |
| Distribution | `[-600,-180] 25%` / `[-180,180] 50%` / `[180,600] 25%` (laddered) |
| Initial price | 1:1, tick `0` |
| Final price | tick `-2` |
| Total gas | ~`0.009` Sepolia ETH (deployer `0.978` → `0.969`) |

## Contract addresses

| Component | Address |
|---|---|
| Uniswap V4 PoolManager (canonical Sepolia) | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| FewFactory | `0x226e65279E177A779522864Ce1dE40c85E2C08A5` |
| AllowlistedFactory (new) | `0x25e63DB69e8d100A147656cfe1d3b87F4cd088ef` |
| RingShareLiqHook | `0x744e0Fd70A64990215A63C9e91fb328f9EC0EaC0` |
| currency0 — `SUNI` | `0x277C85aFd9dCB35C4E8B87f656eEDE3E77c47fFB` |
| currency1 — `SDAI` | `0x6427367769b5373ddAf86037aB7c4E6ef20380F0` |
| fwToken0 (wrapped SUNI) | `0xC83556c88f908902B9ca718787b47f776086b914` |
| fwToken1 (wrapped SDAI) | `0x387c8DE2A6915378191468eA84571f6757aDE013` |
| Swap router (v4-core `PoolSwapTest`) | `0xE0CC9a73c69B8F7468d08d2b8e029C7A633639b9` |

`SUNI` < `SDAI` numerically, so `currency0 = SUNI` and `currency1 = SDAI`. Each fwToken's `token()`
returns its underlying and matches `FewFactory.getWrappedToken(underlying)`.

## Key transactions

| Action | Sepolia transaction | Block |
|---|---|---|
| Deploy AllowlistedFactory | [`0xba7397…187a`](https://sepolia.etherscan.io/tx/0xba73974954682dd59c3a70aa4cf661cd616147eb874dd5c20ad06defea93187a) | `11570344` |
| Deploy hook via factory (CREATE2, mined salt) | [`0x13684d…d0dc`](https://sepolia.etherscan.io/tx/0x13684d8bea3dbf65a092b44f4f46a1bd5cde44eff718678cc3c804289773d0dc) | `11570346` |
| Initialize pool (tick 0, laddered distribution) | [`0xeb0de7…af5a`](https://sepolia.etherscan.io/tx/0xeb0de75dd1ff2e251e62a4c458259949ee1c384577d4e9af71d417380183af5a) | `11570350` |
| Bootstrap (wrap + approve + seed, pool live) | [`0xb76def…ff04`](https://sepolia.etherscan.io/tx/0xb76def78a387a497347ac3c92906d384c1ccdc008d156b23f98019187c6dff04) (final tx of the script) | `11570353` |
| Swap 1: 0.1 SUNI → SDAI | [`0x1c44ef…1ff5`](https://sepolia.etherscan.io/tx/0x1c44efee31badff388dc49233c70150cc6aa693e543f034ba85ca22b631c1ff5) | `11570361` |
| Swap 2: 0.05 SDAI → SUNI (reverse) | [`0x37b8d3…e65f`](https://sepolia.etherscan.io/tx/0x37b8d34a4207301eee45eb926d5866116a6597bb530b19e03949f8c50ce6e65f) | `11570362` |

## Swap results

| Swap | Input | Output | reserve0 after | reserve1 after | tick after |
|---|---|---|---|---|---|
| 1 (SUNI → SDAI) | `0.1` | `0.099682192179556252` | `10.099999999999999997` | `9.900317807820443746` | `-4` |
| 2 (SDAI → SUNI) | `0.05` | `0.049863314015657054` | `10.050136685984342941` | `9.950317807820443743` | `-2` |

Outputs are consistent with a 1:1-priced pool at 0.3% LP fee. Swap 2 succeeding against the
post-swap-1 state also exercises the ERC-6909 claim path: the positive delta from swap 1 was
minted as claims and redeemed at the start of the next JIT cycle.

## Independent verification (cast, post-run)

- Hook address low 14 bits are `0x2AC0`, matching `getHookPermissions()`.
- `owner()` = deployer; `factory()` = `0x25e63D…88ef`; `fewFactory()` = `0x226e65…08A5`.
- Final reserves via `getReserves(key)`: `(10050136685984342941, 9950317807820443743)`.
- Final tick (from `TestSwap` script log): `-2`.
- Runtime bytecode hash: `0xf954147e06973c5fc69e860c56f628cf837d32e29ece809b1e94e9df9b342a8d`.

## Reproduction

```bash
# .env must define: SEPOLIA_RPC_URL, SEPOLIA_PRIVATE_KEY, FEW_FACTORY_ADDR,
# TOKEN_A_ADDR, TOKEN_B_ADDR (SUNI/SDAI above)
export POOL_MANAGER_ADDR=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543

# 1. Deploy AllowlistedFactory
forge script scripts/DeployAllowlistedFactory.s.sol:DeployAllowlistedFactory \
  --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
export ALLOWLISTED_FACTORY_ADDR=0x25e63DB69e8d100A147656cfe1d3b87F4cd088ef

# 2. Deploy hook via factory (mines CREATE2 salt for 0x2AC0 flags)
forge script scripts/CreateHook.s.sol:CreateHook \
  --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
export HOOK_ADDR=0x744e0Fd70A64990215A63C9e91fb328f9EC0EaC0

# 3. Initialize pool (laddered distribution, 1:1 price)
export LADDERED=true
forge script scripts/InitializePool.s.sol:InitializePool \
  --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv

# 4. Bootstrap 10 ether per side (wraps origin tokens -> fwTokens automatically)
export RESERVE_AMOUNT=10000000000000000000
forge script scripts/Bootstrap.s.sol:Bootstrap \
  --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv

# 5. Swap 0.1 SUNI -> SDAI (deploys a fresh PoolSwapTest router)
export SWAP_AMOUNT=100000000000000000 ZERO_FOR_ONE=true
forge script scripts/TestSwap.s.sol:TestSwap \
  --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
export ROUTER_ADDR=0xE0CC9a73c69B8F7468d08d2b8e029C7A633639b9

# 6. Reverse swap 0.05 SDAI -> SUNI (reuses the router)
export SWAP_AMOUNT=50000000000000000 ZERO_FOR_ONE=false
forge script scripts/TestSwap.s.sol:TestSwap \
  --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
```
