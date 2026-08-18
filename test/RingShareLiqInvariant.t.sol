// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityBucket, activeLiquidity} from "alf/types/Distribution.sol";

import {RingShareLiqHook} from "../src/hooks/RingShareLiqHook.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {HookMiner, MockFewFactory, MockFewWrappedToken} from "./RingShareLiqHook.t.sol";

contract RingShareLiqHandler {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    RingShareLiqHook internal immutable HOOK;
    PoolSwapTest internal immutable SWAP_ROUTER;
    PoolKey internal _key;
    PoolId internal immutable POOL_ID;
    Currency internal immutable CURRENCY_0;
    Currency internal immutable CURRENCY_1;
    MockFewWrappedToken internal immutable FW_TOKEN_0;
    MockFewWrappedToken internal immutable FW_TOKEN_1;

    constructor(
        RingShareLiqHook hook,
        PoolSwapTest swapRouter,
        PoolKey memory key,
        MockFewWrappedToken fwToken0,
        MockFewWrappedToken fwToken1
    ) {
        HOOK = hook;
        SWAP_ROUTER = swapRouter;
        _key = key;
        POOL_ID = key.toId();
        CURRENCY_0 = key.currency0;
        CURRENCY_1 = key.currency1;
        FW_TOKEN_0 = fwToken0;
        FW_TOKEN_1 = fwToken1;

        fwToken0.approve(address(hook), type(uint256).max);
        fwToken1.approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(key.currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(swapRouter), type(uint256).max);
    }

    function acceptOwnership() external {
        HOOK.acceptOwnership();
    }

    function deposit0(uint96 seed) external {
        _deposit(CURRENCY_0, FW_TOKEN_0, seed);
    }

    function deposit1(uint96 seed) external {
        _deposit(CURRENCY_1, FW_TOKEN_1, seed);
    }

    function withdraw0(uint96 seed) external {
        _withdraw(CURRENCY_0, seed);
    }

    function withdraw1(uint96 seed) external {
        _withdraw(CURRENCY_1, seed);
    }

    function setLive(bool live) external {
        try HOOK.setPoolLive(_key, live) {} catch {}
    }

    function sweepClaims() external {
        try HOOK.sweepClaims(_key) {} catch {}
    }

    function swap(bool zeroForOne, uint96 seed) external {
        Currency input = zeroForOne ? CURRENCY_0 : CURRENCY_1;
        uint256 balance = input.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = uint256(seed) % balance + 1;
        try SWAP_ROUTER.swap(
            _key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amount.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }

    function _deposit(Currency currency, MockFewWrappedToken fwToken, uint96 seed) private {
        uint256 balance = fwToken.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = uint256(seed) % balance + 1;
        HOOK.deposit(_key, currency, amount);
    }

    function _withdraw(Currency currency, uint96 seed) private {
        uint256 reserve = HOOK.fwReserveOf(POOL_ID, currency);
        if (reserve == 0) return;
        uint256 amount = uint256(seed) % reserve + 1;
        HOOK.withdraw(_key, currency, amount, address(this));
    }
}

contract RingShareLiqInvariantTest is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS = 0x2AC0;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    MockERC20 internal token0;
    MockERC20 internal token1;
    MockFewFactory internal fewFactory;
    MockFewWrappedToken internal fwToken0;
    MockFewWrappedToken internal fwToken1;
    RingShareLiqHook internal hook;
    RingShareLiqHandler internal handler;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;
    PoolId internal poolId;

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);

        MockERC20 tokenA = new MockERC20("A", "A", 18);
        MockERC20 tokenB = new MockERC20("B", "B", 18);
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
        token0.mint(address(this), type(uint128).max);
        token1.mint(address(this), type(uint128).max);

        fewFactory = new MockFewFactory();
        fwToken0 = fewFactory.create(address(token0));
        fwToken1 = fewFactory.create(address(token1));
        token0.approve(address(fwToken0), type(uint256).max);
        token1.approve(address(fwToken1), type(uint256).max);

        bytes memory creationCode = type(RingShareLiqHook).creationCode;
        bytes memory args =
            abi.encode(address(manager), uint32(500_000), address(this), IFewFactory(address(fewFactory)));
        (bytes32 salt,) = HookMiner.mine(address(this), creationCode, args, HOOK_FLAGS, 10_000_000);
        hook = new RingShareLiqHook{salt: salt}(manager, 500_000, address(this), fewFactory);

        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        poolId = key.toId();
        LiquidityBucket[] memory buckets = new LiquidityBucket[](3);
        buckets[0] = LiquidityBucket({tickLower: -600, tickUpper: -180, weightBps: 2500});
        buckets[1] = LiquidityBucket({tickLower: -180, tickUpper: 180, weightBps: 5000});
        buckets[2] = LiquidityBucket({tickLower: 180, tickUpper: 600, weightBps: 2500});
        hook.initializePool(key, RingShareLiqHook.PoolConfig({sqrtPriceX96: SQRT_PRICE_1_1, distribution: buckets}));

        fwToken0.wrap(20_000 ether);
        fwToken1.wrap(20_000 ether);
        fwToken0.approve(address(hook), type(uint256).max);
        fwToken1.approve(address(hook), type(uint256).max);
        hook.bootstrap(key, 10_000 ether, 10_000 ether);

        handler = new RingShareLiqHandler(hook, swapRouter, key, fwToken0, fwToken1);
        assertTrue(fwToken0.transfer(address(handler), 10_000 ether));
        assertTrue(fwToken1.transfer(address(handler), 10_000 ether));
        assertTrue(token0.transfer(address(handler), 10_000 ether));
        assertTrue(token1.transfer(address(handler), 10_000 ether));
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);

        hook.transferOwnership(address(handler));
        handler.acceptOwnership();

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.deposit0.selector;
        selectors[1] = handler.deposit1.selector;
        selectors[2] = handler.withdraw0.selector;
        selectors[3] = handler.withdraw1.selector;
        selectors[4] = handler.setLive.selector;
        selectors[5] = handler.sweepClaims.selector;
        selectors[6] = handler.swap.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_PoolAndWrapperIdentityNeverChange() public view {
        assertEq(PoolId.unwrap(hook.configuredPoolId()), PoolId.unwrap(poolId));
        assertEq(hook.wrappedTokenOf(currency0), address(fwToken0));
        assertEq(hook.wrappedTokenOf(currency1), address(fwToken1));
    }

    function invariant_ReserveLedgersRemainBacked() public view {
        assertGe(fwToken0.balanceOf(address(hook)), hook.fwReserveOf(poolId, currency0));
        assertGe(fwToken1.balanceOf(address(hook)), hook.fwReserveOf(poolId, currency1));
        assertGe(token0.balanceOf(address(hook)), hook.rawReserveOf(poolId, currency0));
        assertGe(token1.balanceOf(address(hook)), hook.rawReserveOf(poolId, currency1));
        assertEq(manager.balanceOf(address(hook), currency0.toId()), hook.claimReserveOf(poolId, currency0));
        assertEq(manager.balanceOf(address(hook), currency1.toId()), hook.claimReserveOf(poolId, currency1));
    }

    function invariant_EmptyActiveLiquidityCannotMovePrice() public {
        if (!hook.livePools(poolId)) return;
        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(address(manager)).getSlot0(poolId);
        (uint256 reserve0, uint256 reserve1) = hook.getEffectiveLiquidity(key);
        if (activeLiquidity(hook.getDistribution(poolId), sqrtPriceX96, tick, reserve0, reserve1) != 0) return;

        (bool ok,) = address(swapRouter)
            .call(
                abi.encodeCall(
                    PoolSwapTest.swap,
                    (
                        key,
                        SwapParams({
                            zeroForOne: true,
                            amountSpecified: -int256(1 ether),
                            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                        }),
                        PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                        bytes("")
                    )
                )
            );
        assertFalse(ok);
        (uint160 afterPrice,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(afterPrice, sqrtPriceX96);
    }
}
