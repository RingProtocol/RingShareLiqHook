// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {AllowlistedFactory} from "../src/factory/AllowlistedFactory.sol";
import {RingShareLiqHook} from "../src/hooks/RingShareLiqHook.sol";

import {RingShareBase} from "./base/RingShareBase.sol";

/// @notice Deploy an `AllowlistedFactory` pinned to this build's `RingShareLiqHook` creation code.
/// @dev    The allowlist is immutable, so the factory only accepts hooks whose creation code
///         matches `keccak256(type(RingShareLiqHook).creationCode)` as compiled here. Rebuilds
///         that change the creation code require a new factory.
///
/// Usage:
///   forge script scripts/DeployAllowlistedFactory.s.sol:DeployAllowlistedFactory \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
contract DeployAllowlistedFactory is RingShareBase {
    function run() public returns (AllowlistedFactory factory) {
        bytes32 hookCodeHash = keccak256(type(RingShareLiqHook).creationCode);

        bytes32[] memory allowlist = new bytes32[](1);
        allowlist[0] = hookCodeHash;

        vm.startBroadcast();
        factory = new AllowlistedFactory(allowlist);
        vm.stopBroadcast();

        console2.log("AllowlistedFactory deployed:", address(factory));
        console2.log("Allowlisted RingShareLiqHook creation code hash:");
        console2.logBytes32(hookCodeHash);
    }
}
