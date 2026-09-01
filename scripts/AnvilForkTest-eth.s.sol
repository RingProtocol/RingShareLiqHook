// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {RingShareLiqHook} from "../src/hooks/RingShareLiqHook.sol";
import {AllowlistedFactory} from "../src/factory/AllowlistedFactory.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";
import {IWETH9} from "../src/interfaces/external/IWETH9.sol";
import {WETH9} from "./DeployWETH9.s.sol";
import {TestToken, MockFewFactory} from "./AnvilForkTest.s.sol";

import {LiquidityBucket} from "alf/types/Distribution.sol";

contract AnvilForkTestEth is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    function run() public {
        address deployer = msg.sender;
        console2.log("=== RingShareLiqHook Native ETH Anvil Test ===");
        console2.log("deployer:", deployer);
        console2.log("deployer balance:", deployer.balance);

        vm.startBroadcast();

        PoolManager poolManager = new PoolManager(deployer);
        WETH9 weth9 = new WETH9();
        MockFewFactory fewFactory = new MockFewFactory();
        TestToken token = new TestToken("Ring Test Token", "RTT");
        token.mint(deployer, 1_000_000 ether);

        address fwWeth = fewFactory.createToken(address(weth9));
        address fwToken = fewFactory.createToken(address(token));

        bytes memory creationCode = type(RingShareLiqHook).creationCode;
        bytes32 hookCodeHash = keccak256(creationCode);
        bytes32[] memory allowlist = new bytes32[](1);
        allowlist[0] = hookCodeHash;
        AllowlistedFactory factory = new AllowlistedFactory(allowlist);
        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(poolManager)),
            uint32(500_000),
            deployer,
            IFewFactory(address(fewFactory)),
            IWETH9(address(weth9))
        );
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        bytes32 salt;
        address predicted;
        for (uint256 i; i < 10_000_000; i++) {
            salt = bytes32(i);
            predicted = Create2.computeAddress(salt, initCodeHash, address(factory));
            if (uint160(predicted) & 0x3FFF == HOOK_FLAGS) break;
        }
        require(uint160(predicted) & 0x3FFF == HOOK_FLAGS, "no salt found");

        address hookAddr = factory.deploy(creationCode, constructorArgs, salt);
        RingShareLiqHook hook = RingShareLiqHook(payable(hookAddr));
        require(hookAddr == predicted, "address mismatch");

        Currency c0 = Currency.wrap(address(0));
        Currency c1 = Currency.wrap(address(token));
        PoolKey memory key =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(hookAddr)});
        PoolId poolId = key.toId();

        LiquidityBucket[] memory buckets = new LiquidityBucket[](3);
        buckets[0] = LiquidityBucket({tickLower: -600, tickUpper: -180, weightBps: 2500});
        buckets[1] = LiquidityBucket({tickLower: -180, tickUpper: 180, weightBps: 5000});
        buckets[2] = LiquidityBucket({tickLower: 180, tickUpper: 600, weightBps: 2500});
        hook.initializePool(key, RingShareLiqHook.PoolConfig({sqrtPriceX96: SQRT_PRICE_1_1, distribution: buckets}));

        uint256 fundedAmount = 102 ether;
        weth9.deposit{value: fundedAmount}();
        IERC20(address(weth9)).approve(fwWeth, type(uint256).max);
        IERC20(address(token)).approve(fwToken, type(uint256).max);
        IFewWrappedToken(fwWeth).wrap(fundedAmount);
        IFewWrappedToken(fwToken).wrap(fundedAmount);
        IERC20(fwWeth).approve(hookAddr, type(uint256).max);
        IERC20(fwToken).approve(hookAddr, type(uint256).max);

        hook.bootstrap(key, 100 ether, 100 ether);
        hook.deposit(key, 1 ether, 1 ether);
        require(IERC20(fwWeth).balanceOf(hookAddr) == 101 ether, "fwWETH was not pulled directly");
        require(address(hook).balance == 0, "deposit unexpectedly transferred ETH");
        (uint256 r0, uint256 r1) = hook.getReserves(key);
        require(r0 == 101 ether && r1 == 101 ether, "unexpected reserve after deposit");

        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(poolManager)));
        IERC20(address(token)).approve(address(router), type(uint256).max);
        (uint256 r0Before, uint256 r1Before) = hook.getReserves(key);
        (, int24 tickBefore,,) = IPoolManager(address(poolManager)).getSlot0(poolId);
        BalanceDelta delta = router.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (uint256 r0After, uint256 r1After) = hook.getReserves(key);
        (, int24 tickAfter,,) = IPoolManager(address(poolManager)).getSlot0(poolId);
        require(r0After != r0Before || r1After != r1Before, "swap did not change reserves");

        hook.sweepClaims(key);
        uint256 reserveBeforeWithdraw = hook.fwReserveOf(poolId, c0);
        hook.withdraw(key, 1 ether, 0, deployer);
        require(hook.fwReserveOf(poolId, c0) == reserveBeforeWithdraw - 1 ether, "withdraw ledger mismatch");

        vm.stopBroadcast();

        console2.log("hook:", hookAddr);
        console2.log("fwWETH:", fwWeth);
        console2.log("delta amount0:", delta.amount0());
        console2.log("delta amount1:", delta.amount1());
        console2.log("reserve0 before/after:", r0Before, r0After);
        console2.log("reserve1 before/after:", r1Before, r1After);
        console2.log("tick before/after:");
        console2.logInt(tickBefore);
        console2.logInt(tickAfter);
        console2.log("=== ALL NATIVE ETH TESTS PASSED ===");
    }
}
