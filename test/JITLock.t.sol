// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {JITInProgress, jitLockFor} from "alf/types/JITLock.sol";

contract JITLockHarness {
    function enter(PoolId id) external {
        jitLockFor(id).enter();
    }

    function clear(PoolId id) external {
        jitLockFor(id).clear();
    }
}

contract JITLockTest is Test {
    JITLockHarness internal harness;
    PoolId internal constant POOL_A = PoolId.wrap(bytes32(uint256(1)));
    PoolId internal constant POOL_B = PoolId.wrap(bytes32(uint256(2)));

    function setUp() public {
        harness = new JITLockHarness();
    }

    function test_RevertCrossPoolEntryWhileAnyJITIsActive() public {
        harness.enter(POOL_A);
        vm.expectRevert(JITInProgress.selector);
        harness.enter(POOL_B);
        harness.clear(POOL_A);
    }

    function test_ClearAllowsNextPoolEntry() public {
        harness.enter(POOL_A);
        harness.clear(POOL_A);
        harness.enter(POOL_B);
        harness.clear(POOL_B);
    }
}
