// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Script} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

abstract contract RingBackedBase is Script {
    function _key() internal view returns (PoolKey memory) {
        address a = vm.envAddress("TOKEN_A_ADDR");
        address b = vm.envAddress("TOKEN_B_ADDR");
        require(a != address(0) && b != address(0) && a != b, "two distinct ERC20s required");
        if (a > b) (a, b) = (b, a);
        uint256 spacing = vm.envOr("TICK_SPACING", uint256(60));
        require(spacing > 0 && spacing <= 200, "spacing 1..200");
        return PoolKey(
            Currency.wrap(a),
            Currency.wrap(b),
            0,
            SafeCast.toInt24(SafeCast.toInt256(spacing)),
            IHooks(vm.envAddress("RING_BACKED_HOOK_ADDR"))
        );
    }
}
