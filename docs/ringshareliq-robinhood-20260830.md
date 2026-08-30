# RingShareLiqHook — Robinhood Chain Deployment (2026-08-30)

> Recompiled `RingShareLiqHook.sol` on `support_eth` branch, propagated the new
> artifacts to downstream projects, and deployed a fresh `AllowlistedFactory`
> pinned to the new creation code hash on Robinhood Chain mainnet (chain 4663).

## Deployment — AllowlistedFactory on Robinhood Chain

| Item | Value |
|---|---|
| Chain | Robinhood Chain mainnet (chain ID `4663`, Arbitrum Orbit L2) |
| RPC | `https://robinhood-mainnet.g.alchemy.com/v2/{ALCHEMY_KEY}` |
| Block explorer | https://robinhoodchain.blockscout.com |
| Deployer / hook owner | `0x87555dd0e101817c1bc7867e32451b080C55f596` |
| **AllowlistedFactory address** | `0x92FF2E6C0a105d26677236e17aee6EAE5Da31ce5` |
| Deploy tx | [`0x74dc79b7…e89a8a`](https://robinhoodchain.blockscout.com/tx/0x74dc79b7282379b9e4f0bc425afd27746967a0e2b42b0b00fe7252eee1e89a8a) |
| Block | `49990788` (L1 ref `25867927`) |
| Gas used | `339,759` |
| Effective gas price | `0.14847 gwei` (148,470,000 wei) |
| Cost | ~0.0000504 ETH |
| Status | ✅ success (`status=1`), code present, allowlist verified on-chain |

> **Address collision note:** The factory address `0x92FF…1ce5` is identical to the
> Ethereum mainnet deployment (see `ringshareliq-mainnet-20260827.md`). This is
> expected — both use the same deployer (`0x8755…f596`) at nonce `0` via CREATE, so
> `keccak256(rlp([sender, nonce]))` resolves to the same address on any EVM chain.
> The two contracts are independent instances on different chains.

### On-chain verification

```bash
RPC="https://robinhood-mainnet.g.alchemy.com/v2/$ALCHEMY_KEY"  # ALCHEMY_KEY from .env
FACTORY=0x92FF2E6C0a105d26677236e17aee6EAE5Da31ce5

# Code present
cast code "$FACTORY" --rpc-url "$RPC" | wc -c   # ~2389 hex chars

# Allowlist entry for the new creation code hash returns true
cast call "$FACTORY" 'isAllowedCreationCode(bytes32)(bool)' \
  0x7fbf425d355a42c8f8f63cedba8f6189962d0cce3185febdd3261f273d03bda6 \
  --rpc-url "$RPC"
# -> true
```

### Deploy command used

```bash
cd /Users/alexla/code/ringprotocol/RingShareLiqHook
set -a; source .env; set +a
forge script scripts/DeployAllowlistedFactory.s.sol:DeployAllowlistedFactory \
  --rpc-url "https://robinhood-mainnet.g.alchemy.com/v2/${ALCHEMY_KEY}" \  # ALCHEY_KEY from .env
  --private-key "$MAINNET_PRIVATE_KEY" \
  --broadcast -vv --slow
```

Broadcast record: `broadcast/DeployAllowlistedFactory.s.sol/4663/run-latest.json`

## Creation code hash (createcodehash)

| Item | Value |
|---|---|
| **`keccak256(creationCode)`** | `0x7fbf425d355a42c8f8f63cedba8f6189962d0cce3185febdd3261f273d03bda6` |
| `keccak256(deployedBytecode)` (runtime) | `0x2de26deb667c3be31897f67079454c742a817db1da62ff0f931c13690a7394de` |
| Creation bytecode size | 23,033 bytes (`0x5cf9` / 46,066 hex chars) |
| Deployed bytecode size | 21,881 bytes (`0x5569` / 43,762 hex chars) |

> The `AllowlistedFactory` whitelists `keccak256(creationCode)` — i.e. the creation
> bytecode **without** constructor args (args are appended at deploy time via
> `abi.encodePacked(creationCode, constructorArgs)`). The hash above is computed
> over `out/RingShareLiqHook.sol/RingShareLiqHook.json` → `bytecode.object`.

## Build configuration

| Item | Value |
|---|---|
| Source | `src/hooks/RingShareLiqHook.sol` |
| Branch | `support_eth` |
| Commit | `f1ccbe1a396d0caaa0cec5065798497633490afd` (`f1ccbe1`) |
| Compiler | solc `0.8.26` |
| EVM version | `cancun` |
| via-IR | `true` |
| Optimizer | enabled, runs `1` |
| forge | `1.5.1-stable` |

## Artifacts propagated

| Destination | Format | Contents |
|---|---|---|
| `/Users/alexla/code/personal/contracttool/contracts/hooks/artifacts/RingShareLiqHook.sol/RingShareLiqHook.json` | Full forge artifact | `abi` + `bytecode` + `deployedBytecode` + metadata |
| `/Users/alexla/code/ring/PriceAdjuster/src/abi/RingShareLiqHook.json` | ABI only | `abi` array (82 entries) — consumed by ethers `Contract` in the hooks monitor UI |

## How to recompute / verify

```bash
cd /Users/alexla/code/ringprotocol/RingShareLiqHook
forge build

# Creation code hash (the value used by AllowlistedFactory's allowlist)
jq -r '.bytecode.object' out/RingShareLiqHook.sol/RingShareLiqHook.json \
  | sed 's/^0x//' \
  | { read h; cast keccak "0x$h"; }
# -> 0x7fbf425d355a42c8f8f63cedba8f6189962d0cce3185febdd3261f273d03bda6

# Runtime code hash (for reference / EIP-7702 / code-verification flows)
jq -r '.deployedBytecode.object' out/RingShareLiqHook.sol/RingShareLiqHook.json \
  | sed 's/^0x//' \
  | { read h; cast keccak "0x$h"; }
# -> 0x2de26deb667c3be31897f67079454c742a817db1da62ff0f931c13690a7394de
```

## Next steps on Robinhood Chain

The factory is deployed and allowlists `0x7fbf…bda6`. Remaining steps to bring up
a full RingShareLiqHook pool on Robinhood Chain:

1. **Deploy the hook** via `CreateHook.s.sol` (mines a CREATE2 salt for the
   `0x2AC0` hook flags). Requires a Uniswap V4 `PoolManager` on Robinhood Chain —
   verify one exists or deploy V4-core first.
2. **Initialize pool** (`InitializePool.s.sol`) with the desired token pair.
3. **Bootstrap reserves** (`Bootstrap.s.sol`).
4. **Update PriceAdjuster** `config/hooks.json` — add a `robinhood` entry under
   `ringshareliq.factoryAddresses` pointing at `0x92FF2E6C0a105d26677236e17aee6EAE5Da31ce5`.

> Note: The `AllowlistedFactory` allowlist is keyed by creation code hash. This
> build's hash (`0x7fbf…bda6`) differs from the previous mainnet/sepolia build
> (`0xd88b…3552`). The Robinhood factory deployed above is already pinned to the
> new hash, so no further allowlist action is needed on this chain.
