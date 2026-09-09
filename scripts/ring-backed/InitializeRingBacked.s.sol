// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {RingBackedLiqHook} from "../../src/hooks/RingBackedLiqHook.sol";
import {RingBackedBase} from "./RingBackedBase.sol";

contract InitializeRingBacked is RingBackedBase {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    function run() external {
        PoolKey memory key = _key();
        RingBackedLiqHook hook = RingBackedLiqHook(address(key.hooks));
        address[] memory route = vm.envAddress("FW_PATH", ",");
        uint256 a0 = vm.envOr("ROUNDING_AMOUNT0", uint256(1_000_000));
        uint256 a1 = vm.envOr("ROUNDING_AMOUNT1", uint256(1_000_000));
        uint160 initialSqrtPriceX96 = uint160(vm.envUint("INITIAL_SQRT_PRICE_X96"));
        vm.startBroadcast();
        hook.initializePool(key, route, initialSqrtPriceX96);
        IERC20(Currency.unwrap(key.currency0)).forceApprove(address(hook), a0);
        IERC20(Currency.unwrap(key.currency1)).forceApprove(address(hook), a1);
        hook.fundRounding(key.currency0, a0);
        hook.fundRounding(key.currency1, a1);
        vm.stopBroadcast();
        console2.log("PoolId");
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("currency0", Currency.unwrap(key.currency0));
        console2.log("currency1", Currency.unwrap(key.currency1));
        console2.log("POOL_LIVE false (add the full-range NFT, then run admin with LIVE=true)");
    }
}
