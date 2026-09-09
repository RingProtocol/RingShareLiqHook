// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @notice FewV2 = a Uniswap V2 fork with 30bps swap fee, hosting Ring's fewToken liquidity.
///         These interfaces are the minimal subset the aggregator hook needs.

interface ISwapV2Factory {
    /// @notice Returns the pair address for two fewTokens (any order), or address(0).
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface ISwapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);

    /// @notice Pair reserves and last-update timestamp. Read inside beforeSwap to price the swap.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    /// @notice V2 swap. Caller must transfer `amountIn` of input token to the pair beforehand.
    /// @dev For a single direction, the unused output amount is 0.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @notice Ring's wrapper for ETH ↔ fwWETH, located in few-periphery.
///         Used when the V4 PoolKey side is native ETH (Currency.wrap(address(0))).
interface IFewETHWrapper {
    function WETH() external view returns (address);
    function fwWETH() external view returns (address);

    /// @notice Pays msg.value of ETH; mints msg.value fwWETH to `to`.
    function wrapETHToFWWETH(address to) external payable returns (uint256);

    /// @notice Pulls `amount` fwWETH from caller; sends `amount` ETH to `to`.
    function unwrapFWWETHToETH(uint256 amount, address to) external returns (uint256);
}

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
