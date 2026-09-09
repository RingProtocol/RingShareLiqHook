// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title RingV2Math
/// @notice Constant-product (x*y=k) swap math for the RingV2 hook, adapted to v4's
///         fee units (pips, 1e6 = 100%). The hook intercepts v4 swaps via
///         `beforeSwapReturnDelta` and prices them against its fwToken reserves using
///         these functions. The fee charged is the pool's static LP fee (`key.fee`).
///
///         Formulas mirror Uniswap V2 but use `1_000_000` as the fee denominator
///         instead of V2's `1000`, so a v4 fee of `3000` (0.3%) maps directly.
library RingV2Math {
    /// @dev Fee denominator: v4 fees are in millionths (1e6 = 100%).
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    /// @notice Compute the output amount for an exact-input swap.
    /// @param amountIn   Gross input amount (before fee deduction).
    /// @param reserveIn  Input token reserve.
    /// @param reserveOut Output token reserve.
    /// @param fee        LP fee in pips (e.g. 3000 = 0.3%).
    /// @return amountOut Output amount the swapper receives.
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint24 fee)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;
        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - fee);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * FEE_DENOMINATOR + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Compute the input amount required for an exact-output swap.
    /// @param amountOut  Desired output amount.
    /// @param reserveIn  Input token reserve.
    /// @param reserveOut Output token reserve.
    /// @param fee        LP fee in pips (e.g. 3000 = 0.3%).
    /// @return amountIn  Input amount the swapper must pay (rounded up to favour the pool).
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut, uint24 fee)
        internal
        pure
        returns (uint256 amountIn)
    {
        if (amountOut == 0) return 0;
        if (amountOut >= reserveOut) return type(uint256).max;
        uint256 numerator = reserveIn * amountOut * FEE_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * (FEE_DENOMINATOR - fee);
        amountIn = numerator / denominator + 1;
    }
}
