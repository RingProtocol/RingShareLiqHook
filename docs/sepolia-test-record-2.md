# Ring Share Liquidity — Sepolia Acceptance Record 2 (current contract)

> This record covers the **current single-pool contract** in `src/` (factory-deployed,
> `Ownable2Step`, hook-only liquidity, flags `0x2AC0`). It supersedes
> [sepolia-test-record.md](./sepolia-test-record.md), which documents an earlier multi-pool
> revision of the codebase.

## Conclusion

On 2026-08-17, the current `RingShareLiqHook` completed an end-to-end run on Ethereum Sepolia with freshly deployed isolated test tokens: factory deployment, CREATE2 hook deployment with salt-mined permission flags, pool initialization with a laddered distribution, bootstrap of reserves, and real swaps in both directions through a `PoolSwapTest` router. All transactions succeeded, and the resulting state was independently re-read via `cast` (not just the scripts' own logs).

This is a testnet technical acceptance. It does not represent production readiness, a profitable economic model, or a completed security audit.

## Deployment snapshot

| Item | Value |
|---|---|
| Chain ID | `11155111` |
| Run block range | ~`11508509` – `11508531` |
| Deployer / hook owner | `0x87555dd0e101817c1bc7867e32451b080C55f596` |
| Compiler profile | default (**solc `0.8.26`** — see deviation note below) |
| EVM / optimizer | Cancun / via-IR / 44,444,444 runs |
| Hook flags | `0x2AC0` (`beforeInitialize`, `beforeAddLiquidity`, `beforeRemoveLiquidity`, `beforeSwap`, `afterSwap`) |
| PoolId | `0x2baae0d24faebcb619e7973574a0ba52acb8736362c3b2dcc5ef88f117fb1801` |
| Pool fee / tickSpacing | `3000` / `60` |
| Distribution | `[-600,-180] 25%` / `[-180,180] 50%` / `[180,600] 25%` |
| Initial price | 1:1, tick `0` |
| Final price | `sqrtPriceX96=79221157794804023777751618716`, tick `-2` |

**Deviation note:** the run was compiled with the default profile (solc `0.8.26`) because the
`solc 0.8.33` download required by `FOUNDRY_PROFILE=sepolia` was rate-limited (HTTP 429) at run
time. Functionality is identical; only bytecode parity with a `0.8.33` build differs. Because the
factory's allowlist pins the creation-code hash, a `0.8.33`-built deployment requires a new factory.

## Contract addresses

| Component | Address |
|---|---|
| Uniswap V4 PoolManager (canonical Sepolia) | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| FewFactory | `0x226e65279E177A779522864Ce1dE40c85E2C08A5` |
| AllowlistedFactory | `0x0C86961c2844F566Aa15B45Afef338ae8C26498F` |
| RingShareLiqHook | `0x393CE21285067963D9DAD61cf95Ec5EB7F9C6ac0` |
| Test currency0 (RTA) | `0x6bE505Ce9b39131B23E7946AF56B545Fd2bd7363` |
| Test currency1 (RTB) | `0x84E88d2E653DE341Bd71860b95f61E3848814aD0` |
| fwToken0 | `0x40395fE2BeFFE885D6514567596EF09Cd1aACB64` |
| fwToken1 | `0x709a2F98c04Dde614A1481b9e087aFcF88de787C` |
| Swap router (v4-core `PoolSwapTest`) | `0x983207B4Bc638DcF5373f66417faEfA08Ae583a0` |

The test tokens are mint-on-demand mocks deployed for this run, with no value. Each side was bootstrapped with a `10 ether` reserve (wrapped to fwTokens through the real FewFactory).

## Key transactions

| Action | Sepolia transaction |
|---|---|
| Deploy test tokens + register fwTokens | [`0x0a17d2…139f`](https://sepolia.etherscan.io/tx/0x0a17d2c290839c6c38757c79448e263fa451865892ccbd71718e557c6b30139f) (+5 more in the same script run) |
| Deploy AllowlistedFactory | [`0x82f2bf…a65f`](https://sepolia.etherscan.io/tx/0x82f2bfddcc157f6e9881c42fddec97492c11a76c2f2c64692130727d2ad4a65f) |
| Deploy hook via factory (CREATE2, mined salt) | [`0xf7c89d…8f88`](https://sepolia.etherscan.io/tx/0xf7c89dbc46d77f13f61567455ae1d8348cf9e45ef66a39500cd7171c938e8f88) |
| Initialize pool (tick 0, laddered distribution) | [`0x7d7e7f…ebf1`](https://sepolia.etherscan.io/tx/0x7d7e7f345ad6f21b7633b9af615fa25a53387d6e7ff5c14fc30ce1cdd80debf1) |
| Bootstrap (wrap + seed reserves, pool live) | [`0x5a7587…1acb`](https://sepolia.etherscan.io/tx/0x5a7587dff9794aef8507c383919a5618cfce25ea471f107bb071995d22641acb) |
| Swap 1: 0.1 token0 → token1 | [`0x261a18…c6ac5`](https://sepolia.etherscan.io/tx/0x261a18ea3ffaea99bd6608dd5095753a0c73889e1fe39cdb7d0d70510e0c6ac5) |
| Swap 2: 0.05 token1 → token0 (reverse) | [`0xc6dd98…3677`](https://sepolia.etherscan.io/tx/0xc6dd989273e2c4848b6e58c5c1a5868381c879c46720d738eff2840fa9233677) |

## Swap results

| Swap | Input | Output | reserve0 after | reserve1 after |
|---|---|---|---|---|
| 1 (token0 → token1) | `0.1` | `0.099682192179556252` | `10.099999999999999997` | `9.900317807820443746` |
| 2 (token1 → token0) | `0.05` | `0.049863314015657054` | `10.050136685984342941` | `9.950317807820443743` |

Outputs are consistent with a 1:1-priced pool at 0.3% LP fee. Swap 2 succeeding against the
post-swap-1 state also exercises the ERC-6909 claim path: the positive delta from swap 1 was
minted as claims and redeemed at the start of the next JIT cycle.

## Independent verification (cast, post-run)

- Hook address low 14 bits are `0x2AC0`, matching `getHookPermissions()`.
- `getDistribution(poolId)` returns `[(-600,-180,2500),(-180,180,5000),(180,600,2500)]`.
- `owner()` = deployer; `factory()` = the AllowlistedFactory above; `isFromFactory(hook)` = `true`.
- Pool slot0 (read via PoolManager `extsload`, `_pools` slot 6): tick `-2`, lpFee `3000`.
- `getIndicativeQuote` for an exact-in 0.1 token0 → token1 swap returns `0.099664482334121086`.
- Gas cost of the whole run: ~`0.016` Sepolia ETH (deployer balance `0.994` → `0.978`).

## Still not covered

- No mainnet deployment or production capital.
- Bytecode-parity deployment under `FOUNDRY_PROFILE=sepolia` (solc `0.8.33`) — pending, see deviation note.
- No pause/resume or admin-operation transactions in this run (covered on an anvil fork instead); the earlier revision's pause behavior is documented in the previous record.
- No proof of profitability after fees, adverse selection, and inventory mark-to-market changes.
- No substitute for a third-party security audit, formal verification, or extended public testnet operation.
