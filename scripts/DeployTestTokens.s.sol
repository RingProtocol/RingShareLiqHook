// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";

import {RingShareBase} from "./base/RingShareBase.sol";

/// @notice Sepolia helper: deploy two mint-on-deploy-style test tokens and register their Few
///         wrappers. `FewFactory.createToken` is permissionless; the mocks mint to the
///         broadcaster. Prints TOKEN_A_ADDR / TOKEN_B_ADDR for the rest of the workflow.
/// @dev    Test tokens only — they exist to give an isolated pair for verifying the hook on a
///         public testnet without touching assets that have value.
///
/// Env: FEW_FACTORY_ADDR, MINT_AMOUNT (default 1,000,000 ether per token, to the broadcaster)
///
/// Usage:
///   forge script scripts/DeployTestTokens.s.sol:DeployTestTokens \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
contract DeployTestTokens is RingShareBase {
    function run() public {
        IFewFactory fewFactory = IFewFactory(vm.envAddress("FEW_FACTORY_ADDR"));
        uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(1_000_000 ether));

        vm.startBroadcast();
        MockERC20 tokenA = new MockERC20("Ring Test A", "RTA", 18);
        MockERC20 tokenB = new MockERC20("Ring Test B", "RTB", 18);
        tokenA.mint(msg.sender, mintAmount);
        tokenB.mint(msg.sender, mintAmount);
        address fwA = fewFactory.createToken(address(tokenA));
        address fwB = fewFactory.createToken(address(tokenB));
        vm.stopBroadcast();

        console2.log("TOKEN_A_ADDR:", address(tokenA));
        console2.log("TOKEN_B_ADDR:", address(tokenB));
        console2.log("fwToken A:", fwA);
        console2.log("fwToken B:", fwB);
    }
}
