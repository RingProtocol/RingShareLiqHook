// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {RingShareLiqHook} from "../src/hooks/RingShareLiqHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IAllowlistedFactory} from "../src/factory/interfaces/IAllowlistedFactory.sol";

import {RingShareBase} from "./base/RingShareBase.sol";

/// @notice Deploy a `RingShareLiqHook` through the `AllowlistedFactory`, mining a CREATE2 salt
///         so the hook address carries the required permission flags (`0x2AC0`).
/// @dev    The factory is the CREATE2 deployer, so salts are mined against the factory address.
///         If the `SALT` env var is set and already yields a valid address it is used as-is;
///         otherwise the script mines one from `SALT_START` (default 0). Expected mining time is
///         ~2^14 iterations.
///
/// Env: ALLOWLISTED_FACTORY_ADDR, POOL_MANAGER_ADDR, FEW_FACTORY_ADDR
///      OWNER (default: broadcaster), MAX_GAS (default 1000000),
///      SALT / SALT_START (optional)
///
/// Usage:
///   forge script scripts/CreateHook.s.sol:CreateHook \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
contract CreateHook is RingShareBase {
    function run() public returns (address hook) {
        address factoryAddr = vm.envAddress("ALLOWLISTED_FACTORY_ADDR");
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDR"));
        IFewFactory fewFactory = IFewFactory(vm.envAddress("FEW_FACTORY_ADDR"));
        address owner = vm.envOr("OWNER", msg.sender);
        uint32 maxGas = uint32(vm.envOr("MAX_GAS", uint256(1_000_000)));

        bytes memory creationCode = type(RingShareLiqHook).creationCode;
        bytes memory constructorArgs = abi.encode(poolManager, maxGas, owner, fewFactory);
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        address predicted = Create2.computeAddress(salt, initCodeHash, factoryAddr);
        if (!_flagsValid(predicted)) {
            uint256 start = vm.envOr("SALT_START", uint256(0));
            (salt, predicted) = _mineSalt(initCodeHash, factoryAddr, start);
        }

        console2.log("owner:", owner);
        console2.log("salt:");
        console2.logBytes32(salt);
        console2.log("predicted hook address:", predicted);

        vm.startBroadcast();
        hook = IAllowlistedFactory(factoryAddr).deploy(creationCode, constructorArgs, salt);
        vm.stopBroadcast();

        require(hook == predicted, "deployed address mismatch");
        console2.log("RingShareLiqHook deployed:", hook);
    }

    function _flagsValid(address addr) internal pure returns (bool) {
        return uint160(addr) & Hooks.ALL_HOOK_MASK == REQUIRED_HOOK_FLAGS;
    }

    function _mineSalt(bytes32 initCodeHash, address factoryAddr, uint256 start)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i = start;; ++i) {
            salt = bytes32(i);
            predicted = Create2.computeAddress(salt, initCodeHash, factoryAddr);
            if (_flagsValid(predicted)) return (salt, predicted);
        }
    }
}
