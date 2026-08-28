// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal interface for the canonical WETH9 contract.
/// @dev Used only to bridge native ETH into the fwToken reserve model when the pool's
///      `currency0` is `address(0)`. The hook receives ETH via `receive()`, wraps it to
///      WETH9, and then wraps the WETH9 into fwWETH through the Few protocol — the same
///      two-step a swapper would perform externally.
interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
