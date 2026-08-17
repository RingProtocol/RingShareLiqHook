# hooks

`RingShareLiqHook` lends a pool's own FewToken reserve to its Uniswap V4 pool as JIT liquidity for
the duration of each swap. Each hook instance is deployed via `AllowlistedFactory` and serves
exactly one pool, configured through `initializePool` + `bootstrap`; reserve accounting is isolated
per hook, and this repository does not implement a global cross-pool capital pool.

## Build and test

```sh
git submodule update --init --recursive
forge build
forge test
```

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
- [Sepolia acceptance record — current contract](docs/sepolia-test-record-2.md)
- [Sepolia acceptance record (earlier codebase revision)](docs/sepolia-test-record.md)
