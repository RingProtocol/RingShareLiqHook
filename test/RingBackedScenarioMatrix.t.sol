// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {RingLPPlanner} from "../src/libraries/RingLPPlanner.sol";
import {RingBackedLiqHookTest} from "./RingBackedLiqHook.t.sol";

/// @notice Diagnostic matrix for the economic split between the permanent v4 LP and Ring JIT.
/// @dev Run through scripts/ring-backed/simulate-scenarios.sh. Values use 18-decimal raw units.
contract RingBackedScenarioMatrix is RingBackedLiqHookTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint160 private constant SEPOLIA_PRICE = 79_228_162_514_264_337_593_543_950;
    uint128 private constant BASE_LIQUIDITY = 10_000_000_000_000_000_000;

    function test_Matrix_AlignedSell1kRht() public {
        _runIsolated("aligned / sell 1,000 RHT", 1_000_000 ether, 1 ether, true, true, 1_000 ether);
    }

    function test_Matrix_AlignedSell10kRht() public {
        _runIsolated("aligned / sell 10,000 RHT", 1_000_000 ether, 1 ether, true, true, 10_000 ether);
    }

    function test_Matrix_AlignedSell100kRht() public {
        _runIsolated("aligned / sell 100,000 RHT", 1_000_000 ether, 1 ether, true, true, 100_000 ether);
    }

    function test_Matrix_AlignedSell500kRht() public {
        _runIsolated("aligned / sell 500,000 RHT", 1_000_000 ether, 1 ether, true, true, 500_000 ether);
    }

    function test_Matrix_AlignedExactBuy10kRht() public {
        _runIsolated("aligned / exact buy 10,000 RHT", 1_000_000 ether, 1 ether, false, false, 10_000 ether);
    }

    function test_Matrix_AlignedSell001Weth() public {
        _runIsolated("aligned / sell 0.01 WETH", 1_000_000 ether, 1 ether, false, true, 0.01 ether);
    }

    function test_Matrix_ShallowRingSell10kRht() public {
        _runIsolated("shallow Ring / sell 10,000 RHT", 100_000 ether, 0.1 ether, true, true, 10_000 ether);
    }

    function test_Matrix_DeepRingSell100kRht() public {
        _runIsolated("deep Ring / sell 100,000 RHT", 10_000_000 ether, 10 ether, true, true, 100_000 ether);
    }

    function test_Matrix_RingRht20PctExpensiveBuy() public {
        _runIsolated("Ring RHT 20% more expensive / buy RHT", 1_000_000 ether, 1.2 ether, false, true, 0.01 ether);
    }

    function test_Matrix_RingRht20PctCheaperBuy() public {
        _runIsolated("Ring RHT 20% cheaper / buy RHT", 1_000_000 ether, 0.8 ether, false, true, 0.01 ether);
    }

    function test_Matrix_RingRht2xExpensiveSell() public {
        _runIsolated("Ring RHT 2x expensive / sell RHT", 1_000_000 ether, 2 ether, true, true, 10_000 ether);
    }

    function test_Matrix_RingRht2xExpensiveBuy() public {
        _runIsolated("Ring RHT 2x expensive / buy RHT", 1_000_000 ether, 2 ether, false, true, 0.01 ether);
    }

    function test_Matrix_RingRht50PctCheaperSell() public {
        _runIsolated("Ring RHT 50% cheaper / sell RHT", 1_000_000 ether, 0.5 ether, true, true, 10_000 ether);
    }

    function test_Matrix_RingRht50PctCheaperBuy() public {
        _runIsolated("Ring RHT 50% cheaper / buy RHT", 1_000_000 ether, 0.5 ether, false, true, 0.01 ether);
    }

    function test_SequentialPriceDrift() public {
        _configure(1_000_000 ether, 1 ether, 999);
        console2.log("============================================================");
        console2.log("SEQUENCE: five RHT sells followed by five WETH sells");
        for (uint256 i; i < 5; ++i) {
            _runTrade("RHT -> WETH", true, true, 50_000 ether);
        }
        for (uint256 i; i < 5; ++i) {
            _runTrade("WETH -> RHT", false, true, 0.05 ether);
        }
    }

    function _runIsolated(
        string memory name,
        uint256 ringRht,
        uint256 ringWeth,
        bool zeroForOne,
        bool exactInput,
        uint256 amount
    ) private {
        _configure(ringRht, ringWeth, 100);
        console2.log("============================================================");
        console2.log(name);
        console2.log("RING_INITIAL_RHT", ringRht);
        console2.log("RING_INITIAL_WETH", ringWeth);
        _runTrade(name, zeroForOne, exactInput, amount);
    }

    function _configure(uint256 ringRht, uint256 ringWeth, uint256 nonce) private {
        _resetRingReserves(ringRht, ringWeth);
        address[] memory route = new address[](2);
        route[0] = fwA;
        route[1] = fwB;
        (hook, key) = _deployAt(route, 60, nonce, SEPOLIA_PRICE);
        IERC20(a).approve(address(hook), 1_000_000);
        IERC20(b).approve(address(hook), 1_000_000);
        hook.fundRounding(Currency.wrap(a), 1_000_000);
        hook.fundRounding(Currency.wrap(b), 1_000_000);

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        IERC20(a).approve(address(lp), type(uint256).max);
        IERC20(b).approve(address(lp), type(uint256).max);
        expectedBaseLiquidity = BASE_LIQUIDITY;
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(key.tickSpacing),
                TickMath.maxUsableTick(key.tickSpacing),
                int256(uint256(BASE_LIQUIDITY)),
                0
            ),
            ""
        );
        hook.setPoolLive(true);
    }

    function _runTrade(string memory label, bool zeroForOne, bool exactInput, uint256 amount) private {
        int256 specified = exactInput ? -SafeCast.toInt256(amount) : SafeCast.toInt256(amount);
        (uint160 priceBefore, int24 tickBefore,,) = pm.getSlot0(key.toId());
        (uint256 lp0Before, uint256 lp1Before) = _baseAmounts(priceBefore);
        (uint256 ringA0, uint256 ringB0) = _ringReserves();
        uint256 userIn0 = IERC20(zeroForOne ? a : b).balanceOf(address(this));
        uint256 userOut0 = IERC20(zeroForOne ? b : a).balanceOf(address(this));

        try hook.quote(key, zeroForOne, specified) returns (
            uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory plan
        ) {
            console2.log("TRADE", label);
            console2.log("ZERO_FOR_ONE", zeroForOne);
            console2.log("EXACT_INPUT", exactInput);
            console2.log("SPECIFIED_AMOUNT", amount);
            console2.log("QUOTE_TOTAL_INPUT", plan.amountIn);
            console2.log("QUOTE_TOTAL_OUTPUT", plan.amountOut);
            console2.log("QUOTE_RING_INPUT", ringIn);
            console2.log("QUOTE_RING_OUTPUT", ringOut);
            console2.log("QUOTE_JIT_LIQUIDITY", plan.liquidity);
            console2.log("QUOTE_BASE_INPUT_APPROX", plan.amountIn > ringIn ? plan.amountIn - ringIn : 0);
            console2.log("QUOTE_BASE_OUTPUT", plan.amountOut > ringOut ? plan.amountOut - ringOut : 0);
            console2.log(
                "QUOTE_BASE_OUTPUT_SHARE_BPS",
                plan.amountOut == 0 ? 0 : (plan.amountOut - ringOut) * 10_000 / plan.amountOut
            );

            _trade(zeroForOne, exactInput, amount);

            (uint160 priceAfter, int24 tickAfter,,) = pm.getSlot0(key.toId());
            (uint256 lp0After, uint256 lp1After) = _baseAmounts(priceAfter);
            (uint256 ringA1, uint256 ringB1) = _ringReserves();
            uint256 actualInput = userIn0 - IERC20(zeroForOne ? a : b).balanceOf(address(this));
            uint256 actualOutput = IERC20(zeroForOne ? b : a).balanceOf(address(this)) - userOut0;

            assertEq(actualInput, plan.amountIn, "actual input differs from quote");
            assertEq(actualOutput, plan.amountOut, "actual output differs from quote");
            assertEq(pm.getLiquidity(key.toId()), BASE_LIQUIDITY, "permanent liquidity changed");

            console2.log("ACTUAL_USER_INPUT", actualInput);
            console2.log("ACTUAL_USER_OUTPUT", actualOutput);
            console2.log("V4_PRICE_BEFORE_X96", uint256(priceBefore));
            console2.log("V4_PRICE_AFTER_X96", uint256(priceAfter));
            console2.log("V4_TICK_BEFORE");
            console2.logInt(tickBefore);
            console2.log("V4_TICK_AFTER");
            console2.logInt(tickAfter);
            console2.log("BASE_LP_TOKEN0_BEFORE", lp0Before);
            console2.log("BASE_LP_TOKEN0_AFTER", lp0After);
            console2.log("BASE_LP_TOKEN1_BEFORE", lp1Before);
            console2.log("BASE_LP_TOKEN1_AFTER", lp1After);
            console2.log("RING_RHT_BEFORE", ringA0);
            console2.log("RING_RHT_AFTER", ringA1);
            console2.log("RING_WETH_BEFORE", ringB0);
            console2.log("RING_WETH_AFTER", ringB1);
        } catch (bytes memory reason) {
            console2.log("TRADE", label);
            console2.log("QUOTE_FAILED_SELECTOR");
            console2.logBytes4(reason.length >= 4 ? bytes4(reason) : bytes4(0));
        }
    }

    function _baseAmounts(uint160 price) private view returns (uint256 amount0, uint256 amount1) {
        return LiquidityAmounts.getAmountsForLiquidity(
            price,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(key.tickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(key.tickSpacing)),
            BASE_LIQUIDITY
        );
    }

    function _ringReserves() private view returns (uint256 reserveA, uint256 reserveB) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (pair.token0() == fwA) return (r0, r1);
        return (r1, r0);
    }
}
