// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {LiquidityAmounts as UniswapLiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {LiquidityAmounts as RingLiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";

contract LiquidityAmountsTest is Test {
    function testFuzz_MatchesUniswapLiquidityMath(uint96 amount0, uint96 amount1) public pure {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(0);
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(600);

        assertEq(
            RingLiquidityAmounts.getLiquidityForAmount0(sqrtLowerX96, sqrtUpperX96, amount0),
            UniswapLiquidityAmounts.getLiquidityForAmount0(sqrtLowerX96, sqrtUpperX96, amount0)
        );
        assertEq(
            RingLiquidityAmounts.getLiquidityForAmount1(sqrtLowerX96, sqrtUpperX96, amount1),
            UniswapLiquidityAmounts.getLiquidityForAmount1(sqrtLowerX96, sqrtUpperX96, amount1)
        );
        assertEq(
            RingLiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1),
            UniswapLiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1)
        );
    }

    function test_MatchesUniswapOutsideRange() public pure {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(-600);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(600);
        uint160 belowRangeX96 = TickMath.getSqrtPriceAtTick(-1200);
        uint160 aboveRangeX96 = TickMath.getSqrtPriceAtTick(1200);
        uint256 amount0 = 10_000 ether;
        uint256 amount1 = 10_000 ether;

        assertEq(
            RingLiquidityAmounts.getLiquidityForAmounts(belowRangeX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1),
            UniswapLiquidityAmounts.getLiquidityForAmounts(belowRangeX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1)
        );
        assertEq(
            RingLiquidityAmounts.getLiquidityForAmounts(aboveRangeX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1),
            UniswapLiquidityAmounts.getLiquidityForAmounts(aboveRangeX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1)
        );
    }

    function testFuzz_MatchesUniswapAcrossPriceRanges(
        int24 lowerSeed,
        int24 currentSeed,
        int24 upperSeed,
        uint64 amount0,
        uint64 amount1
    ) public pure {
        int24 lowerTick = int24(bound(lowerSeed, -600_000, -1));
        int24 upperTick = int24(bound(upperSeed, 1, 600_000));
        int24 currentTick = int24(bound(currentSeed, lowerTick, upperTick));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currentTick);
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(lowerTick);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(upperTick);

        assertEq(
            RingLiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1),
            UniswapLiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, amount0, amount1)
        );
    }

    function test_RevertWhenLiquidityDoesNotFitUint128() public {
        uint160 sqrtLowerX96 = TickMath.getSqrtPriceAtTick(-60);
        uint160 sqrtUpperX96 = TickMath.getSqrtPriceAtTick(60);

        vm.expectRevert(SafeCast.SafeCastOverflow.selector);
        this.getLiquidityForAmount0(sqrtLowerX96, sqrtUpperX96, type(uint128).max);
    }

    function getLiquidityForAmount0(uint160 sqrtLowerX96, uint160 sqrtUpperX96, uint256 amount0)
        external
        pure
        returns (uint128)
    {
        return RingLiquidityAmounts.getLiquidityForAmount0(sqrtLowerX96, sqrtUpperX96, amount0);
    }
}
