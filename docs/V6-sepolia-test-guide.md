# RingShareLiqHook — Sepolia 部署与测试指南

> 本文档指导你在 Sepolia 测试网（或 anvil fork）上部署 RingShareLiqHook 并验证 JIT swap 机制。

---

## 前置条件

### 1. 环境变量

在 `hooks/` 目录下创建 `.env`：

```bash
# Sepolia RPC (或 anvil fork URL)
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/<your-key>

# 部署者私钥 (需要 ETH 作为 gas)
SEPOLIA_PRIVATE_KEY=0x...

# FewFactory 地址 (Sepolia 上已部署)
FEW_FACTORY_ADDR=0x...

# 交易对 token 地址 (Sepolia 上的 ERC20)
TOKEN_A_ADDR=0x...
TOKEN_B_ADDR=0x...
```

### 2. 余额要求

具体数量由 `RESERVE_AMOUNT`、`BOOTSTRAP_LIQUIDITY` 和 `SWAP_TEST_AMOUNT` 决定。脚本默认值下，
currency0 至少需要 113 tokens，currency1 至少需要 112 tokens；也可以设置
`DEPLOY_TEST_TOKENS=true`，让脚本部署并铸造隔离测试币。

### 3. fwToken 必须已创建

`FewFactory.getWrappedToken(TOKEN_A)` 和 `getWrappedToken(TOKEN_B)` 必须返回非零地址。
如果未创建，先调用 `FewFactory.createToken(TOKEN_A_ADDR)`。

---

## 部署

### Anvil Fork (推荐先在本地验证)

```bash
# 1. 启动 anvil fork
anvil --port 8545 \
  --fork-url $SEPOLIA_RPC_URL \
  --fork-block-number 11457001 \
  --balance 10000

# 2. 给部署者注资 (anvil only)
cast rpc anvil_setBalance $DEPLOYER 0x1000000000000000000 --rpc-url http://127.0.0.1:8545
# 从 token owner 转账 (需要 impersonate)
cast rpc anvil_impersonateAccount $TOKEN_OWNER --rpc-url http://127.0.0.1:8545
cast send $TOKEN_A "transfer(address,uint256)" $DEPLOYER 20000ether --from $TOKEN_OWNER --rpc-url http://127.0.0.1:8545 --unlocked
cast send $TOKEN_B "transfer(address,uint256)" $DEPLOYER 20000ether --from $TOKEN_OWNER --rpc-url http://127.0.0.1:8545 --unlocked

# 3. 部署
source .env
FOUNDRY_PROFILE=sepolia forge script script/DeployRingShareLiqSepolia.s.sol:DeployRingShareLiqSepolia \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $SEPOLIA_PRIVATE_KEY \
  --broadcast -vv
```

### Sepolia 主网

```bash
source .env
FOUNDRY_PROFILE=sepolia forge script script/DeployRingShareLiqSepolia.s.sol:DeployRingShareLiqSepolia \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $SEPOLIA_PRIVATE_KEY \
  --broadcast -vv \
  --verify --verifier etherscan --verifier-url <explorer-api>
```

### 部署输出

脚本会在日志中输出：
- Hook 地址 (CREATE2 部署，地址由 salt + flags 决定)
- PoolOperator 地址
- fwToken0 / fwToken1 地址
- 储备验证（应与 `RESERVE_AMOUNT` 一致）

**记录 Hook 地址**，后续测试需要用到。

---

## Swap 测试

### 运行 TestSwapSepolia 脚本

```bash
source .env
export HOOK_ADDR=<部署输出的 Hook 地址>
export SWAP_1_AMOUNT=100000000000000000  # 0.1 token，按 18 decimals
export SWAP_2_AMOUNT=50000000000000000   # 0.05 token
export SWAP_3_AMOUNT=1000000000000000    # 0.001 token

FOUNDRY_PROFILE=sepolia forge script script/TestSwapSepolia.s.sol:TestSwapSepolia \
  --rpc-url http://127.0.0.1:8545 \
  --private-key $SEPOLIA_PRIVATE_KEY \
  --broadcast -vv
```

### 测试内容

脚本执行 3 个 swap 验证不同场景：

| Swap | 方向 | 数量 | 场景 |
|------|------|------|------|
| 1 | token0 → token1 | `SWAP_1_AMOUNT`，默认 0.1 | 正常 JIT 注入 + swap + JIT 移除 |
| 2 | token1 → token0 | `SWAP_2_AMOUNT`，默认 0.05 | 反向 swap，验证 JIT 双向工作 |
| 3 | token0 → token1 | `SWAP_3_AMOUNT`，默认 0.001 | 禁用 pool 后 swap，验证 hook 优雅降级 |

### 预期输出

日志应依次出现 `Swap 1`、`Swap 2`、禁用 pool 后的 `Swap 3`、重新启用 pool，以及
`All swaps completed successfully!`。实际输出数量取决于环境变量、当前 pool 价格和已有流动性，
不应把某次运行的数值当成固定验收值。

### 验证要点

1. **Swap 1**: token0 减少、token1 增加，hook 完成 JIT 注入和移除。
2. **Hook 储备变化**: reserve0 增加、reserve1 减少，方向与交易一致。
3. **Swap 2**: 反向交易成功，储备方向反转。
4. **Swap 3**: 禁用 hook 后交易仍成功，但只使用 bootstrap LP。

---

## 已知问题与修复

### `2^32` 精度 Bug (已修复)

**问题**: 仓库原有的本地 `LiquidityAmounts` 实现把 Q96 sqrt price 与 Q128 分母混用，
而 `SqrtPriceMath.getAmount1Delta` 按 Q96 计算。round-trip 因此放大 `2^32 = 4,294,967,296` 倍。

**影响**: `_computeAllocations` 计算的 `need1` 是实际需求的 42.9 亿倍，导致 `_settleDebt` 永远 revert `InsufficientReserve()`。

**修复**: `src/libraries/LiquidityAmounts.sol` 统一使用 Q96，并对 `uint128` 转换做溢出检查：
- `getLiquidityForAmount1`: `L = amount1 * Q96 / (sqrtB - sqrtA)` (而非 Q128)
- `getLiquidityForAmount0`: `intermediate = sqrtA * sqrtB / Q96` (而非 Q128)

### SwapOperator 结算顺序 (已修复)

**问题**: V4 的 `sync()` 会记录 PoolManager 当前余额。如果 caller 在 `sync()` 后没有立即转账并
`settle()`，hook 内部的 `sync()`/`settle()` 会覆盖这份快照。

**修复**: `TestSwapSepolia` 在 swap 完成后连续执行 `sync → transfer → settle`；
`V4DirectSwapRouter` 则在 swap 前连续完成这三步，两种流程都不会留下跨 hook 调用的未结算快照。

---

## 手动验证 (cast)

### 检查 hook 状态

```bash
# 储备
cast call $HOOK "getReserves((address,address,uint24,int24,address))(uint256,uint256)" \
  "$C0,$C1,3000,60,$HOOK" --rpc-url $RPC

# 是否启用
cast call $HOOK "isEnabled((address,address,uint24,int24,address))(bool)" \
  "$C0,$C1,3000,60,$HOOK" --rpc-url $RPC

# 当前分布
cast call $HOOK "getDistribution((address,address,uint24,int24,address))" \
  "$C0,$C1,3000,60,$HOOK" --rpc-url $RPC

# Pool 状态
cast call $POOL_MANAGER "getSlot0(bytes32)(uint160,int24,uint24,uint24)" \
  $(cast call $POOL_MANAGER "poolId((address,address,uint24,int24,address))(bytes32)" \
  "$C0,$C1,3000,60,$HOOK" --rpc-url $RPC) --rpc-url $RPC
```

### 手动 swap (需要 SwapOperator)

部署 SwapOperator 后，approve token 并调用 `doSwap`：

```bash
# Approve
cast send $TOKEN_A "approve(address,uint256)" $SWAP_OP $(cast maxuint) --rpc-url $RPC --private-key $PK
cast send $TOKEN_B "approve(address,uint256)" $SWAP_OP $(cast maxuint) --rpc-url $RPC --private-key $PK

# Swap 0.1 token0 -> token1（18 decimals）
cast send $SWAP_OP "doSwap((address,address,uint24,int24,address),bool,uint128,address)" \
  "$C0,$C1,3000,60,$HOOK" true 100000000000000000 $DEPLOYER \
  --rpc-url $RPC --private-key $PK
```
