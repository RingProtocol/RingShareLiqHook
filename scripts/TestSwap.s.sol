// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {RingShareLiqHook} from "../src/hooks/RingShareLiqHook.sol";

import {RingShareBase} from "./base/RingShareBase.sol";

/// @notice Execute a swap against the hook's pool through a `PoolSwapTest` router and log the
///         effect on the hook's reserves. Works on anvil forks and public testnets.
/// @dev    The router pays from the broadcaster (`transferFrom`), so both tokens are approved
///         to it. Reuse a deployed router by setting `ROUTER_ADDR`; otherwise a fresh
///         `PoolSwapTest` is deployed.
///
/// Env: HOOK_ADDR, POOL_MANAGER_ADDR, TOKEN_A_ADDR, TOKEN_B_ADDR, FEE, TICK_SPACING,
///      SWAP_AMOUNT (default 0.1 ether, exact input), ZERO_FOR_ONE (default true),
///      ROUTER_ADDR (optional)
///
/// Usage:
///   forge script scripts/TestSwap.s.sol:TestSwap \
///     --rpc-url http://127.0.0.1:8545 --private-key $ANVIL_KEY --broadcast -vv
contract TestSwap is RingShareBase {
    using SafeCast for uint256;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function run() public {
        RingShareLiqHook hook = RingShareLiqHook(payable(vm.envAddress("HOOK_ADDR")));
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDR"));
        PoolKey memory key = _poolKey(address(hook));

        uint256 amountIn = vm.envOr("SWAP_AMOUNT", uint256(0.1 ether));
        bool zeroForOne = vm.envOr("ZERO_FOR_ONE", true);

        (uint256 r0Before, uint256 r1Before) = hook.getReserves(key);
        (, int24 tickBefore,,) = poolManager.getSlot0(key.toId());

        vm.startBroadcast();
        address routerAddr = vm.envOr("ROUTER_ADDR", address(0));
        PoolSwapTest router = routerAddr == address(0) ? new PoolSwapTest(poolManager) : PoolSwapTest(routerAddr);
        // Approve only non-native currencies to the router; native ETH is sent as msg.value.
        if (!key.currency0.isAddressZero()) {
            IERC20(Currency.unwrap(key.currency0)).approve(address(router), type(uint256).max);
        }
        IERC20(Currency.unwrap(key.currency1)).approve(address(router), type(uint256).max);

        BalanceDelta delta = router.swap{value: key.currency0.isAddressZero() && zeroForOne ? amountIn : 0}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        (uint256 r0After, uint256 r1After) = hook.getReserves(key);
        (, int24 tickAfter,,) = poolManager.getSlot0(key.toId());

        console2.log("router:", address(router));
        console2.log("swap direction zeroForOne:", zeroForOne);
        console2.log("delta amount0:", delta.amount0());
        console2.log("delta amount1:", delta.amount1());
        console2.log("reserve0 before/after:", r0Before, r0After);
        console2.log("reserve1 before/after:", r1Before, r1After);
        console2.log("tick before/after:");
        console2.logInt(tickBefore);
        console2.logInt(tickAfter);
    }
}
