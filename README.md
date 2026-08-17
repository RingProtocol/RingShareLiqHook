# hooks

`RingShareLiqHook` assigns FewToken reserves to individual Uniswap V4 pools and injects each pool's
own reserve as JIT liquidity for a swap. A single hook can operate several pools, but reserve
accounting is isolated by `PoolId`; this repository does not implement a global cross-pool capital
pool.

## Build and test

```sh
forge build
forge test
```

## Deploy RingShareLiqHook on Sepolia

For an isolated end-to-end test, set `DEPLOY_TEST_TOKENS=true`; the script deploys two mint-on-deploy
test tokens, creates their Few wrappers, initializes the pool, proves the bootstrap LP can exit and
be restored, deposits configurable reserves, and executes a real router swap. Existing token
addresses may instead be supplied with `TOKEN_A_ADDR` and `TOKEN_B_ADDR`.

Required variables are `SEPOLIA_RPC_URL`, `SEPOLIA_PRIVATE_KEY`, and `FEW_FACTORY_ADDR`. Optional
amounts are `RESERVE_AMOUNT` (default `100 ether`), `BOOTSTRAP_LIQUIDITY` (default `10 ether`), and
`SWAP_TEST_AMOUNT` (default `1 ether`). Then run:

```sh
FOUNDRY_PROFILE=sepolia forge script script/DeployRingShareLiqSepolia.s.sol:DeployRingShareLiqSepolia \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --broadcast -v
```

The script prints the hook, test tokens, wrapped tokens, PoolOperator, swap router, pool price, and
post-swap reserves. Save the broadcast artifact and verify the printed addresses before describing a
Sepolia deployment as complete.

The current verified Sepolia deployment and acceptance evidence are recorded in
[`docs/V6-sepolia.md`](docs/V6-sepolia.md).

## Legacy V3 material

The `remix/` directory is retained only as a historical RingFallbackV3 deployment reference. The
V3 contract and salt-mining script are no longer part of this repository, so those instructions are
not a supported or runnable deployment path.
