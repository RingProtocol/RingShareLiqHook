# Ring Share Liquidity — Sepolia Acceptance Record

> **Historical record.** This acceptance was performed against an **earlier revision** of the
> codebase (a multi-pool hook with admin/`OwnedHook` access control, external bootstrap LP,
> and hook flags `0x20c0`). The current source in `src/` is a redesigned **single-pool** hook
> deployed via `AllowlistedFactory`, with `Ownable2Step` ownership, hook-only liquidity, and
> flags `0x2AC0`. The transactions below are on-chain facts about that earlier deployment;
> they do not verify the current contract. See [ringshareliqhook.md](./ringshareliqhook.md) for the
> current design.

## Conclusion

On 2026-08-13, `RingShareLiqHook` completed end-to-end acceptance with isolated test assets on Ethereum Sepolia. All 28 deployment and configuration transactions succeeded; hook deployment, pool creation, bootstrap LP add / full exit / restore, FewToken reserve deposits, pool enablement, laddered range configuration, and a real router swap all landed on chain.

This was a testnet technical acceptance. It does not represent production readiness, a profitable economic model, or a completed mainnet security audit.

## Deployment snapshot

| Item | Value |
|---|---|
| Chain ID | `11155111` |
| Source commit at deployment (pre-rebase) | `2ae3983` |
| Compiler profile | `FOUNDRY_PROFILE=sepolia` |
| Solidity | `0.8.33` |
| EVM / optimizer | Cancun / via-IR / 44,444,444 runs |
| On-chain runtime keccak256 | `0x5c350a26591fef99d06603fd315ff5dc531c2464b287d70460b16226a33e80f0` |
| Runtime template keccak256 | `0xa5558c93634b6fc684719456342f486e91c2e8431215e3d6603418d5fc0a0d92` |
| Hook flags | `0x20c0` |
| PoolId | `0xee6da6aa90191efd93e1fcd0061d78d5a94462482fc7f7a4ec241de7705a25b4` |
| Initial price | 1:1, tick `0` |
| Post-acceptance price | `sqrtPriceX96=79214036558416731460367637563`, tick `-4` |

## Contract addresses

| Component | Address |
|---|---|
| Uniswap V4 PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| FewFactory | `0x226e65279E177A779522864Ce1dE40c85E2C08A5` |
| RingShareLiqHook | `0x777c0526e3C0500e27103dc7AA076C5e2FB7A0c0` |
| Test currency0 | `0x43ceB50e2Ed2Ed6B3137D6b839BBB065318E7525` |
| Test currency1 | `0xca8Efe301FeD4Fcd547C2Db6e18D3F375Bb8Ac4A` |
| fwToken0 | `0x8cCBa4e8Fe913A10aD6EbC5ACE6409f924A8F11C` |
| fwToken1 | `0xABB9eC50D4A849c5276a378D836446EbD8BF7F6A` |
| PoolOperator | `0x048e19d64F17AE3871A3FeEF34F9710E92ECf6a5` |
| V4DirectSwapRouter | `0xc14Cc10f5996410e412a50c0753871b10e1F62Aa` |

The test tokens were mint-on-deploy ERC-20s created specifically for this acceptance, with no mainnet value. Each currency had a `10 ether` reserve deposited into the hook, bootstrap LP liquidity was `1 ether`, and the acceptance swap input `0.1 ether` of currency0 for an output of `0.099682224025481434 ether` of currency1.

## Key transactions

| Action | Sepolia transaction |
|---|---|
| Deploy hook | [`0x166298…75e3`](https://sepolia.etherscan.io/tx/0x166298de17ab31afb8f7e9df98d245a58217edae1259d204a28ef74885ee75e3) |
| Initialize pool | [`0x68456b…158d`](https://sepolia.etherscan.io/tx/0x68456b34853bfc1725e7329c4c2e88c51be80d127a992673de733f625ce9158d) |
| Add bootstrap LP | [`0xcd06e5…6208`](https://sepolia.etherscan.io/tx/0xcd06e5c5046734ac31e8f65d5e8729aef0c1b4c35f937854f2f0fb04c43f6208) |
| Full bootstrap LP exit | [`0x825620…809a`](https://sepolia.etherscan.io/tx/0x8256200c0ebf2cbb5c6354c10d3679d2eff318b5b7b338ac3dd276c887ac809a) |
| Restore bootstrap LP | [`0x436e84…e36e`](https://sepolia.etherscan.io/tx/0x436e84a08a9210c7e98f5b0fc3462d4733c2230a7dd529785dd5c4cef30fe36e) |
| Deposit currency0 reserve | [`0x215bd2…039c`](https://sepolia.etherscan.io/tx/0x215bd2f12dbbefad142c4c781a4d29ff737f26f3ecc4ba519d9c23e902bb039c) |
| Deposit currency1 reserve | [`0xf9ffde…e288`](https://sepolia.etherscan.io/tx/0xf9ffde9a2d2dfe538eefd5f64ad918fb681acd466584f453c8e683ab7f5ae288) |
| Enable pool | [`0xf980ac…735b`](https://sepolia.etherscan.io/tx/0xf980ac872e6ad60731171920dbba06d70fc2e85b716cda380505950e869e735b) |
| Configure distribution | [`0xc0f1e4…9728`](https://sepolia.etherscan.io/tx/0xc0f1e4fb99fed45185ecbeda897984a78abc6322560d5eed683b86d1d2069728) |
| Real router swap | [`0x66a86b…f631`](https://sepolia.etherscan.io/tx/0x66a86bc15d62be9fbcc9f2b4ae405524c36de34812dfe51d926f76cd4068f631) |

## Independent verification

- The broadcast file records `28/28` receipts with `status=0x1`.
- PublicNode and Alchemy returned identical status and block heights for the key transactions; the hook, both test tokens, both fwTokens, PoolOperator, and the router all have non-empty bytecode.
- Both RPCs returned: pool `enabled=true`; hook admin and PoolOperator caller set to the deployer address; router pointing at the official Sepolia PoolManager.
- Both RPCs returned post-acceptance reserves: currency0 `10.099821136987245289`, currency1 `9.900496070603591438`.
- The hook address's low 14 bits are `0x20c0`, matching the `beforeInitialize + beforeSwap + afterSwap` permissions of that revision.
- The hook runtime compiled under the Sepolia profile was `20,108 bytes`, leaving `4,468 bytes` of headroom under the EIP-170 limit.
- After the rebase, the project was rebuilt with all 22 constructor immutable slots zeroed; the runtime template matched the on-chain bytecode byte-for-byte — the only differences in the full on-chain bytecode came from the deployed PoolManager and FewFactory immutable addresses.

## Still not covered

- No mainnet deployment or production capital.
- No proof that the strategy is profitable after fees, adverse selection, and inventory mark-to-market changes.
- No substitute for a third-party security audit, formal verification, or extended public testnet operation.
- What was verified is a per-pool isolated reserve model, not a global cross-pool capital pool.
