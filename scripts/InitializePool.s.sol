// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RingShareLiqHook} from "../src/hooks/RingShareLiqHook.sol";

import {RingShareBase} from "./base/RingShareBase.sol";

/// @notice Initialize the hook's pool with an initial price and liquidity distribution.
/// @dev    Owner-only. The pool is created NOT live: swaps revert with `PoolNotLive` until
///         `bootstrap` seeds the reserve. Both currencies must be ERC-20 tokens with fwTokens
///         registered in the FewFactory (`WrappedTokenNotFound` otherwise); native ETH is not
///         supported.
///
/// Env: HOOK_ADDR, TOKEN_A_ADDR, TOKEN_B_ADDR, FEE (default 3000), TICK_SPACING (default 60),
///      SQRT_PRICE_X96 (default 1:1), LADDERED (default false -> single full-range bucket)
///
/// Usage:
///   forge script scripts/InitializePool.s.sol:InitializePool \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
contract InitializePool is RingShareBase {
    using PoolIdLibrary for PoolKey;

    function run() public returns (int24 tick) {
        RingShareLiqHook hook = RingShareLiqHook(vm.envAddress("HOOK_ADDR"));
        PoolKey memory key = _poolKey(address(hook));
        uint160 sqrtPriceX96 = uint160(vm.envOr("SQRT_PRICE_X96", uint256(SQRT_PRICE_1_1)));

        RingShareLiqHook.PoolConfig memory config =
            RingShareLiqHook.PoolConfig({sqrtPriceX96: sqrtPriceX96, distribution: _distribution(key.tickSpacing)});

        vm.startBroadcast();
        tick = hook.initializePool(key, config);
        vm.stopBroadcast();

        _logKey(key);
        console2.log("pool initialized at tick:", tick);
        console2.log("PoolId:");
        console2.logBytes32(PoolId.unwrap(key.toId()));
    }
}
