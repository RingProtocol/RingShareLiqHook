// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {RingShareLiqHook} from "../src/hooks/RingShareLiqHook.sol";
import {RingShareBase} from "./base/RingShareBase.sol";

/// @notice Seed the pool's reserve with fwTokens and flip the pool live (one-shot).
/// @dev    Owner-only. For each currency the script verifies the broadcaster's fwToken balance,
///         approves the hook, then calls `bootstrap`.
///         Reverts with `PoolAlreadyBootstrapped` on a live pool — use the Admin script's
///         `deposit` action for later top-ups.
///
/// Env: HOOK_ADDR, TOKEN_A_ADDR, TOKEN_B_ADDR, FEE, TICK_SPACING,
///      RESERVE_AMOUNT (default 100 ether, both sides),
///      RESERVE_AMOUNT0 / RESERVE_AMOUNT1 (optional per-side overrides, in currency0/currency1)
///
/// Usage:
///   forge script scripts/Bootstrap.s.sol:Bootstrap \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
contract Bootstrap is RingShareBase {
    using SafeERC20 for IERC20;

    function run() public {
        RingShareLiqHook hook = RingShareLiqHook(payable(vm.envAddress("HOOK_ADDR")));
        PoolKey memory key = _poolKey(address(hook));

        uint256 amount = vm.envOr("RESERVE_AMOUNT", uint256(100 ether));
        uint256 amount0 = vm.envOr("RESERVE_AMOUNT0", amount);
        uint256 amount1 = vm.envOr("RESERVE_AMOUNT1", amount);

        vm.startBroadcast();
        _fund(key.currency0, amount0, hook);
        _fund(key.currency1, amount1, hook);
        hook.bootstrap(key, amount0, amount1);
        vm.stopBroadcast();

        (uint256 r0, uint256 r1) = hook.getReserves(key);
        console2.log("pool bootstrapped and live");
        console2.log("reserve0:", r0);
        console2.log("reserve1:", r1);
    }

    /// @dev Ensure the broadcaster holds `amount` of the pool's pinned fwToken and grant the hook
    ///      an allowance for it. Native currency reserves use fwWETH exactly like any other fwToken.
    function _fund(Currency currency, uint256 amount, RingShareLiqHook hook) internal {
        if (amount == 0) return;
        address fwToken = hook.wrappedTokenOf(currency);
        require(fwToken != address(0), "fwToken not found");
        require(IERC20(fwToken).balanceOf(msg.sender) >= amount, "insufficient fwToken balance");
        IERC20(fwToken).forceApprove(address(hook), amount);
    }
}
