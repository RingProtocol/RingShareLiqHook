# Ring Share Liquidity — Sepolia 验收记录

## 结论

2026-08-13，`RingShareLiqHook` 已在 Ethereum Sepolia 完成隔离测试资产的端到端验收。28 笔部署和配置交易全部成功；hook 部署、建池、引导 LP 添加/完整退出/恢复、FewToken 储备存入、启用、阶梯区间配置和真实 router swap 均已上链。

这是测试网技术验收，不代表生产启用、经济模型盈利或主网安全审计完成。

## 部署快照

| 项目 | 值 |
|---|---|
| Chain ID | `11155111` |
| 部署源码提交（rebase 前） | `2ae3983` |
| 编译 profile | `FOUNDRY_PROFILE=sepolia` |
| Solidity | `0.8.33` |
| EVM / optimizer | Cancun / via-IR / 44,444,444 runs |
| 链上 runtime keccak256 | `0x5c350a26591fef99d06603fd315ff5dc531c2464b287d70460b16226a33e80f0` |
| Runtime template keccak256 | `0xa5558c93634b6fc684719456342f486e91c2e8431215e3d6603418d5fc0a0d92` |
| Hook flags | `0x20c0` |
| PoolId | `0xee6da6aa90191efd93e1fcd0061d78d5a94462482fc7f7a4ec241de7705a25b4` |
| 初始价格 | 1:1，tick `0` |
| 验收后价格 | `sqrtPriceX96=79214036558416731460367637563`，tick `-4` |

## 合约地址

| 组件 | 地址 |
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

测试币是此次验收专用的 mint-on-deploy ERC-20，没有主网价值。每种货币向 hook 存入 `10 ether` 储备，引导 LP 流动性为 `1 ether`，验收 swap 输入 `0.1 ether` currency0，输出 `0.099682224025481434 ether` currency1。

## 关键交易

| 动作 | Sepolia 交易 |
|---|---|
| 部署 hook | [`0x166298…75e3`](https://sepolia.etherscan.io/tx/0x166298de17ab31afb8f7e9df98d245a58217edae1259d204a28ef74885ee75e3) |
| 初始化 pool | [`0x68456b…158d`](https://sepolia.etherscan.io/tx/0x68456b34853bfc1725e7329c4c2e88c51be80d127a992673de733f625ce9158d) |
| 添加引导 LP | [`0xcd06e5…6208`](https://sepolia.etherscan.io/tx/0xcd06e5c5046734ac31e8f65d5e8729aef0c1b4c35f937854f2f0fb04c43f6208) |
| 完整退出引导 LP | [`0x825620…809a`](https://sepolia.etherscan.io/tx/0x8256200c0ebf2cbb5c6354c10d3679d2eff318b5b7b338ac3dd276c887ac809a) |
| 恢复引导 LP | [`0x436e84…e36e`](https://sepolia.etherscan.io/tx/0x436e84a08a9210c7e98f5b0fc3462d4733c2230a7dd529785dd5c4cef30fe36e) |
| 存入 currency0 储备 | [`0x215bd2…039c`](https://sepolia.etherscan.io/tx/0x215bd2f12dbbefad142c4c781a4d29ff737f26f3ecc4ba519d9c23e902bb039c) |
| 存入 currency1 储备 | [`0xf9ffde…e288`](https://sepolia.etherscan.io/tx/0xf9ffde9a2d2dfe538eefd5f64ad918fb681acd466584f453c8e683ab7f5ae288) |
| 启用 pool | [`0xf980ac…735b`](https://sepolia.etherscan.io/tx/0xf980ac872e6ad60731171920dbba06d70fc2e85b716cda380505950e869e735b) |
| 配置 distribution | [`0xc0f1e4…9728`](https://sepolia.etherscan.io/tx/0xc0f1e4fb99fed45185ecbeda897984a78abc6322560d5eed683b86d1d2069728) |
| 真实 router swap | [`0x66a86b…f631`](https://sepolia.etherscan.io/tx/0x66a86bc15d62be9fbcc9f2b4ae405524c36de34812dfe51d926f76cd4068f631) |

## 独立复核

- 广播文件记录 `28/28` receipts 为 `status=0x1`。
- PublicNode 与 Alchemy 返回相同的关键交易状态和块高；hook、两种测试币、两个 fwToken、PoolOperator 和 router 均有非空 bytecode。
- 两个 RPC 均返回：pool `enabled=true`；hook admin 和 PoolOperator caller 为部署地址；router 指向官方 Sepolia PoolManager。
- 两个 RPC 均返回验收后储备：currency0 `10.099821136987245289`，currency1 `9.900496070603591438`。
- hook 地址低 14 位为 `0x20c0`，与 `beforeInitialize + beforeSwap + afterSwap` 权限一致。
- Sepolia profile 编译出的 hook runtime 为 `20,108 bytes`，距离 EIP-170 上限还有 `4,468 bytes`。
- rebase 后重新构建并将 22 个构造函数 immutable 插槽归零，runtime template 与链上逐字节一致；完整链上 bytecode 的差异只来自已部署的 PoolManager 和 FewFactory immutable 地址。

## 仍未覆盖

- 没有主网部署或生产资金。
- 没有证明策略在费用、逆向选择和库存市值变化之后盈利。
- 没有替代第三方安全审计、形式化验证或长时间公开测试网运行。
- 当前验证的是每池独立储备模型，不是全局跨池资金池。
