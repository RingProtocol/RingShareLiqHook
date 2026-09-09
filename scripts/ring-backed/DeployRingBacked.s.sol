// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";
import {ISwapV2Factory} from "../../src/interfaces/external/IFewV2.sol";
import {AllowlistedFactory} from "../../src/factory/AllowlistedFactory.sol";
import {RingBackedLiqHook} from "../../src/hooks/RingBackedLiqHook.sol";
import {RingLPRouter} from "../../src/routers/RingLPRouter.sol";

contract DeployRingBacked is Script {
    function run() external {
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDR"));
        IFewFactory few = IFewFactory(vm.envAddress("FEW_FACTORY_ADDR"));
        ISwapV2Factory dex = ISwapV2Factory(vm.envAddress("FEW_V2_FACTORY_ADDR"));
        address owner = vm.envOr("OWNER", msg.sender);
        require(
            address(manager).code.length > 0 && address(few).code.length > 0 && address(dex).code.length > 0,
            "missing dependencies"
        );
        bytes memory code = type(RingBackedLiqHook).creationCode;
        bytes memory args = abi.encode(manager, few, dex, owner);
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = keccak256(code);
        bytes32 initHash = keccak256(bytes.concat(code, args));
        vm.startBroadcast();
        AllowlistedFactory factory = new AllowlistedFactory(hashes);
        uint256 salt = vm.envOr("SALT_START", uint256(0));
        address predicted;
        for (;; ++salt) {
            predicted = Create2.computeAddress(bytes32(salt), initHash, address(factory));
            if (uint160(predicted) & 0x3fff == 0x2ac0 && predicted.code.length == 0) break;
        }
        address hook = factory.deploy(code, args, bytes32(salt));
        require(hook == predicted, "address mismatch");
        RingLPRouter router = new RingLPRouter(manager);
        vm.stopBroadcast();
        console2.log("RING_BACKED_FACTORY_ADDR", address(factory));
        console2.log("RING_BACKED_HOOK_ADDR", hook);
        console2.log("RING_LP_ROUTER_ADDR", address(router));
        console2.log("OWNER", owner);
        console2.log("salt", salt);
    }
}
