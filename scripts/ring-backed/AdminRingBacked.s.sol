// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {RingBackedLiqHook} from "../../src/hooks/RingBackedLiqHook.sol";
import {RingBackedBase} from "./RingBackedBase.sol";

contract AdminRingBacked is RingBackedBase {
    using SafeERC20 for IERC20;

    function run() external {
        RingBackedLiqHook hook = RingBackedLiqHook(vm.envAddress("RING_BACKED_HOOK_ADDR"));
        bytes32 action = keccak256(bytes(vm.envString("ACTION")));
        vm.startBroadcast();
        if (action == keccak256("setPoolLive")) {
            hook.setPoolLive(vm.envBool("LIVE"));
        } else if (action == keccak256("fundRounding")) {
            address token = vm.envAddress("TOKEN_ADDR");
            uint256 amount = vm.envUint("AMOUNT");
            IERC20(token).forceApprove(address(hook), amount);
            hook.fundRounding(Currency.wrap(token), amount);
        } else if (action == keccak256("withdrawRounding")) {
            hook.withdrawRounding(
                Currency.wrap(vm.envAddress("TOKEN_ADDR")), vm.envUint("AMOUNT"), vm.envOr("TO", msg.sender)
            );
        } else {
            revert("unknown ACTION");
        }
        vm.stopBroadcast();
    }
}
