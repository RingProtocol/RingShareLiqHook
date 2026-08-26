// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {RingShareLiqHook} from "../src/hooks/RingShareLiqHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";

import {RingShareBase} from "./base/RingShareBase.sol";

/// @notice Owner operations on a live hook, selected by the `ACTION` env var.
/// @dev    All actions are owner-gated on the hook and revert while a JIT cycle is in flight.
///
/// Actions and their extra env vars:
///   deposit         TOKEN_ADDR (underlying currency), AMOUNT (fwToken pulled from broadcaster)
///   withdraw        TOKEN_ADDR, AMOUNT, TO (default: broadcaster)
///   setPoolLive     LIVE (bool) — pause/resume JIT service; swaps revert `PoolNotLive` while false
///   setDistribution LADDERED (bool, default false -> single full-range bucket)
///   sweepClaims     — redeem outstanding ERC-6909 claims back into the reserve
///
/// Common env: HOOK_ADDR, TOKEN_A_ADDR, TOKEN_B_ADDR, FEE, TICK_SPACING
///
/// Usage:
///   ACTION=deposit TOKEN_ADDR=$TOKEN_A_ADDR AMOUNT=10000000000000000000 \
///     forge script scripts/Admin.s.sol:Admin \
///     --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast -vv
contract Admin is RingShareBase {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    function run() public {
        RingShareLiqHook hook = RingShareLiqHook(vm.envAddress("HOOK_ADDR"));
        PoolKey memory key = _poolKey(address(hook));
        string memory action = vm.envString("ACTION");
        bytes32 a = keccak256(bytes(action));

        vm.startBroadcast();
        if (a == keccak256("deposit")) {
            _deposit(hook, key);
        } else if (a == keccak256("withdraw")) {
            _withdraw(hook, key);
        } else if (a == keccak256("setPoolLive")) {
            bool live = vm.envBool("LIVE");
            hook.setPoolLive(key, live);
            console2.log("setPoolLive:", live);
        } else if (a == keccak256("setDistribution")) {
            hook.setDistribution(key, _distribution(key.tickSpacing));
            console2.log("distribution updated");
        } else if (a == keccak256("sweepClaims")) {
            hook.sweepClaims(key);
            console2.log("claims swept into reserve");
        } else {
            revert("unknown ACTION; expected deposit|withdraw|setPoolLive|setDistribution|sweepClaims");
        }
        vm.stopBroadcast();

        (uint256 r0, uint256 r1) = hook.getReserves(key);
        console2.log("reserve0:", r0);
        console2.log("reserve1:", r1);
    }

    function _deposit(RingShareLiqHook hook, PoolKey memory key) internal {
        Currency currency = Currency.wrap(vm.envAddress("TOKEN_ADDR"));
        uint256 amount = vm.envUint("AMOUNT");
        address fwToken = hook.fewFactory().getWrappedToken(Currency.unwrap(currency));
        require(fwToken != address(0), "fwToken not found");
        IERC20(fwToken).forceApprove(address(hook), amount);
        if (currency == key.currency0) {
            hook.deposit(key, amount, 0);
        } else {
            require(currency == key.currency1, "TOKEN_ADDR not in pool");
            hook.deposit(key, 0, amount);
        }
        console2.log("deposited fwToken:", fwToken, amount);
    }

    function _withdraw(RingShareLiqHook hook, PoolKey memory key) internal {
        Currency currency = Currency.wrap(vm.envAddress("TOKEN_ADDR"));
        uint256 amount = vm.envUint("AMOUNT");
        address to = vm.envOr("TO", msg.sender);
        if (currency == key.currency0) {
            hook.withdraw(key, amount, 0, to);
        } else {
            require(currency == key.currency1, "TOKEN_ADDR not in pool");
            hook.withdraw(key, 0, amount, to);
        }
        console2.log("withdrew to:", to, amount);
    }
}
