// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {RingBackedLiqHook} from "../../src/hooks/RingBackedLiqHook.sol";
import {RingLPRouter} from "../../src/routers/RingLPRouter.sol";
import {RingLPPlanner} from "../../src/libraries/RingLPPlanner.sol";
import {RingBackedBase} from "./RingBackedBase.sol";

contract SwapRingBacked is RingBackedBase {
    using SafeERC20 for IERC20;

    function run() external {
        PoolKey memory key = _key();
        RingBackedLiqHook hook = RingBackedLiqHook(address(key.hooks));
        RingLPRouter router = RingLPRouter(vm.envAddress("RING_LP_ROUTER_ADDR"));
        require(address(router.poolManager()) == address(hook.poolManager()), "manager mismatch");
        bool forward = vm.envOr("ZERO_FOR_ONE", true);
        int256 specified = vm.envInt("AMOUNT_SPECIFIED");
        uint256 limit = vm.envUint("AMOUNT_LIMIT");
        uint256 deadline = vm.envUint("DEADLINE");
        bool syncOnly = vm.envOr("SYNC_ONLY", false);
        uint160 priceLimit = uint160(
            vm.envOr(
                "SQRT_PRICE_LIMIT_X96", uint256(forward ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
            )
        );
        if (!syncOnly) {
            (uint256 ri, uint256 ro, RingLPPlanner.Plan memory p) = hook.quote(key, forward, specified);
            console2.log("Ring input/output", ri, ro);
            console2.log("LP input/output", p.amountIn, p.amountOut);
        }
        uint256 budget = specified < 0 ? SafeCast.toUint256(-specified) : limit;
        vm.startBroadcast();
        IERC20(Currency.unwrap(forward ? key.currency0 : key.currency1)).forceApprove(address(router), budget);
        SwapParams memory params = SwapParams(forward, specified, priceLimit);
        BalanceDelta d =
            syncOnly ? router.syncPrice(key, params, limit, deadline) : router.swap(key, params, limit, deadline);
        vm.stopBroadcast();
        console2.log("amount0", d.amount0());
        console2.log("amount1", d.amount1());
    }
}
