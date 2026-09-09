// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Shared helpers for the RingShareLiqHook workflow scripts.
///
/// Common environment variables:
///   HOOK_ADDR        - deployed RingShareLiqHook address
///   TOKEN_A_ADDR     - one side of the pair (order-independent; sorted by the helper)
///   TOKEN_B_ADDR     - the other side of the pair
///   FEE              - static LP fee in pips (default 3000); dynamic fees are rejected by the hook
///   TICK_SPACING     - pool tick spacing (default 60)
abstract contract RingShareBase is Script {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @dev Hook permission flags required by `RingShareLiqHook.getHookPermissions`, encoded in
    ///      the low 14 bits of the hook address. `BaseHook.validateHookAddress` enforces the match.
    ///      beforeInitialize(13) + beforeAddLiquidity(11) + beforeRemoveLiquidity(9) +
    ///      beforeSwap(7) + afterSwap(6) + beforeSwapReturnDelta(3) = 0x2AC8.
    uint160 internal constant REQUIRED_HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    function _poolKey(address hook) internal view returns (PoolKey memory key) {
        address tokenA = vm.envAddress("TOKEN_A_ADDR");
        address tokenB = vm.envAddress("TOKEN_B_ADDR");
        uint24 fee = uint24(vm.envOr("FEE", uint256(3000)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        key = _buildKey(hook, tokenA, tokenB, fee, tickSpacing);
    }

    function _buildKey(address hook, address tokenA, address tokenB, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory key)
    {
        (Currency c0, Currency c1) = _sortCurrencies(tokenA, tokenB);
        key = PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: tickSpacing, hooks: IHooks(hook)});
    }

    function _sortCurrencies(address tokenA, address tokenB) internal pure returns (Currency, Currency) {
        require(tokenA != tokenB, "identical tokens");
        return tokenA < tokenB
            ? (Currency.wrap(tokenA), Currency.wrap(tokenB))
            : (Currency.wrap(tokenB), Currency.wrap(tokenA));
    }

    function _logKey(PoolKey memory key) internal pure {
        console2.log("currency0:", Currency.unwrap(key.currency0));
        console2.log("currency1:", Currency.unwrap(key.currency1));
        console2.log("fee:", key.fee);
        console2.log("tickSpacing:", key.tickSpacing);
    }
}
