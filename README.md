# Ring Share Liquidity Hook

## Ring-backed JIT LP

`RingBackedLiqHook` combines permanent full-range v4 liquidity with an optional real, per-order
JIT position sourced from Ring FewV2. Both swap-return-delta flags remain disabled. The pool uses
zero v4 LP fee, a fixed canonical Ring route, and a prefunded `RingLPRouter`. FewV2's 30 bps
per-hop fee remains and the hook adds no surcharge. Only full-range external positions are
accepted; unmatched orders safely execute against the permanent position without touching Ring.
An owner-funded rounding reserve has a hard per-swap loss cap of 8 raw units per currency.

See [design, limits, and Sepolia scripts](docs/ring-backed-lp-design.md) and the
[Chinese mechanism overview](docs/ring-backed-jit-liquidity.zh-CN.md). The implementation has local
fixture tests and has been exercised against a live Sepolia Ring pair and Uniswap v4 pool.

## Original owner-reserve JIT LP

`RingShareLiqHook` lends a pool's own FewToken reserve to its Uniswap V4 pool as JIT liquidity for
the duration of each swap. Each hook instance is deployed via `AllowlistedFactory` and serves
exactly one pool, configured through `initializePool` + `bootstrap`; reserve accounting is isolated
per hook, and this repository does not implement a global cross-pool capital pool.

The contract is pre-production: it has not completed an independent audit, the current bytecode is
not deployed, and Uniswap routing/discovery has not been verified.

## Build and test

```sh
git submodule update --init --recursive
forge build
forge test
```

The three dependencies are committed as fixed gitlinks, so the commands above reproduce the
reviewed dependency versions. CI runs formatting, production and Sepolia builds with size checks,
medium/high lint, unit tests, fuzz tests, and invariants.

## Deployment scripts

`scripts/` contains the Foundry scripts for the full workflow:

- `DeployAllowlistedFactory.s.sol` — deploy the CREATE2 factory allowlisted to this build's hook
- `CreateHook.s.sol` — mine the `0x2AC0` flag salt and deploy a `RingShareLiqHook` via the factory
- `InitializePool.s.sol` — create the pool with an initial price and distribution
- `Bootstrap.s.sol` — wrap tokens, seed the reserve, and flip the pool live
- `Admin.s.sol` — owner operations (`deposit` / `withdraw` / `setPoolLive` / `setDistribution` / `sweepClaims`)
- `DeployTestTokens.s.sol` — deploy isolated test tokens and register their fwTokens (testnets)
- `TestSwap.s.sol` — execute a swap through a `PoolSwapTest` router and log the reserve effects

See the [Sepolia deployment & testing guide](docs/sepolia-test-guide.md) for usage and environment
variables.

## Documentation

- [Hook introduction and design](docs/ringshareliqhook.md)
- [Sepolia deployment & testing guide](docs/sepolia-test-guide.md)
- [Beginner's guide](docs/tutorial.md)
- [Historical Sepolia acceptance record — pre-hardening bytecode](docs/sepolia-test-record-2.md)
- [Sepolia acceptance record (earlier codebase revision)](docs/sepolia-test-record.md)
