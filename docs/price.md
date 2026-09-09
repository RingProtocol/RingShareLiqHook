# RingV2 安全建议

RingV2 模式下,hook 用 V2 恒定乘积公式(`x*y=k`)对 fwToken 储备定价,原生 V4 池子不执行 swap。以下是针对新架构的安全建议(按优先级):

1. **价格合理性校验**:在 `_beforeSwap` 里对比 V2 隐含价格与外部参考价(如 V4 池子的 `sqrtPriceX96` 或 TWAP),偏离超过阈值则 revert。V2 公式本身不会产生异常价格,但储备比例可能被大额单边 swap 推到极端值,后续 swap 会以不利价格成交。
2. **最小储备检查**:`bootstrap` 已要求两侧储备非零。可考虑在 `beforeSwap` 里增加最小输出量检查,避免 dust swap 消耗 gas 但不产生有效成交。
3. **`getEffectiveLiquidity` / `getIndicativeQuote` 的捐赠敏感性**:这两个视图把 ERC-6909 claims 上限设为 `PoolManager` 当前的物理余额,而该余额可被第三方捐赠污染。如需更保守的视图,可单独暴露一个不依赖 `balanceOf(poolManager)` 的版本。
4. **`receive()` 来源校验**:当前 `receive()` 接受任意来源的 ETH。建议加来源校验:只接受 WETH9 和 PoolManager 的转账,拒绝任意来源的 ETH,避免 `ethHeld` 被人为抬高。
5. **滑点保护**:V2 公式对大额 swap 天然有滑点,但前端用户应自行设置 `sqrtPriceLimitX96` 或在路由层做最小输出量检查,避免被抢跑。

第 1、4 点是针对核心风险的关键缓解;其余是加固。
