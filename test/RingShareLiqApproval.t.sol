// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {BaseHook} from "../src/utils/BaseHook.sol";
import {RingShareLiqHook} from "../src/hooks/RingShareLiqHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";

contract ZeroFirstApprovalToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint256 public approveAttempts;

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        ++approveAttempts;
        if (allowance[msg.sender][spender] != 0 && amount != 0) return false;
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

contract FalseApprovalToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }
}

contract RingShareLiqHookApprovalHarness is RingShareLiqHook {
    constructor() RingShareLiqHook(IPoolManager(address(1)), uint32(500_000), msg.sender, IFewFactory(address(1))) {}

    function validateHookAddress(BaseHook) internal pure override {}

    function approveDirectly(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function ensureApproved(Currency currency, address fwToken) external {
        _ensureApproved(currency, fwToken);
    }

    function approvalCached(address token) external view returns (bool) {
        return _fwApproved[token];
    }
}

contract RingShareLiqApprovalTest is Test {
    RingShareLiqHookApprovalHarness internal hook;
    address internal constant WRAPPER = address(0xFEE1);

    function setUp() public {
        hook = new RingShareLiqHookApprovalHarness();
    }

    function test_ForceApproveSupportsZeroFirstTokens() public {
        ZeroFirstApprovalToken token = new ZeroFirstApprovalToken();
        hook.approveDirectly(token, WRAPPER, 1);

        hook.ensureApproved(Currency.wrap(address(token)), WRAPPER);

        assertEq(token.allowance(address(hook), WRAPPER), type(uint256).max);
        assertEq(token.approveAttempts(), 4);
        assertTrue(hook.approvalCached(address(token)));
    }

    function test_RevertAndDoNotCacheFailedApproval() public {
        FalseApprovalToken token = new FalseApprovalToken();

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        hook.ensureApproved(Currency.wrap(address(token)), WRAPPER);

        assertFalse(hook.approvalCached(address(token)));
    }
}
