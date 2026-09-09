// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {RingBackedLiqHook} from "../src/hooks/RingBackedLiqHook.sol";
import {RingLPRouter} from "../src/routers/RingLPRouter.sol";
import {RingLPPlanner} from "../src/libraries/RingLPPlanner.sol";
import {FewV2Math} from "../src/libraries/FewV2Math.sol";
import {ISwapV2Factory} from "../src/interfaces/external/IFewV2.sol";
import {MockFewFactory, MockFewWrappedToken, HookMiner} from "./RingShareLiqHook.t.sol";

contract BackingPair is Test {
    address public immutable token0;
    address public immutable token1;
    uint112 private r0;
    uint112 private r1;
    address public callbackTarget;
    bytes public callbackData;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, 0);
    }

    function sync() public {
        r0 = SafeCast.toUint112(IERC20(token0).balanceOf(address(this)));
        r1 = SafeCast.toUint112(IERC20(token1).balanceOf(address(this)));
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function swap(uint256 o0, uint256 o1, address to, bytes calldata) external {
        require(o0 + o1 > 0 && o0 < r0 && o1 < r1, "output");
        if (o0 > 0) require(IERC20(token0).transfer(to, o0));
        if (o1 > 0) require(IERC20(token1).transfer(to, o1));
        if (callbackTarget != address(0)) {
            (bool ok,) = callbackTarget.call(callbackData);
            require(!ok, "reentry succeeded");
        }
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 i0 = b0 > r0 - o0 ? b0 - (r0 - o0) : 0;
        uint256 i1 = b1 > r1 - o1 ? b1 - (r1 - o1) : 0;
        require((b0 * 1000 - i0 * 3) * (b1 * 1000 - i1 * 3) >= uint256(r0) * r1 * 1_000_000, "K");
        sync();
    }
}

contract BackingFactory is ISwapV2Factory {
    mapping(address => mapping(address => address)) public getPair;

    function set(address a, address b, address p) external {
        getPair[a][b] = p;
        getPair[b][a] = p;
    }
}

contract RingBackedLiqHookTest is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PoolManager manager;
    IPoolManager pm;
    MockFewFactory few;
    BackingFactory dex;
    RingBackedLiqHook hook;
    RingLPRouter router;
    PoolKey key;
    address a;
    address b;
    address fwA;
    address fwB;
    BackingPair pair;
    uint128 expectedBaseLiquidity = 100 ether;

    function setUp() public {
        manager = new PoolManager(address(this));
        pm = IPoolManager(address(manager));
        few = new MockFewFactory();
        dex = new BackingFactory();
        a = address(new MockERC20("A", "A", 18));
        b = address(new MockERC20("B", "B", 18));
        if (a > b) (a, b) = (b, a);
        fwA = address(few.create(a));
        fwB = address(few.create(b));
        pair = _pair(fwA, fwB, 10_000 ether, 10_000 ether);
        router = new RingLPRouter(pm);
        address[] memory route = new address[](2);
        route[0] = fwA;
        route[1] = fwB;
        (hook, key) = _deploy(route, 60, 0);
        MockERC20(a).mint(address(this), 1_000_000 ether);
        MockERC20(b).mint(address(this), 1_000_000 ether);
        IERC20(a).approve(address(router), type(uint256).max);
        IERC20(b).approve(address(router), type(uint256).max);
        _fundBuffers(hook);
    }

    function _deploy(address[] memory route, int24 spacing, uint256 nonce)
        internal
        returns (RingBackedLiqHook h, PoolKey memory k)
    {
        return _deployAt(route, spacing, nonce, 79228162514264337593543950336);
    }

    function _deployAt(address[] memory route, int24 spacing, uint256 nonce, uint160 initialPrice)
        internal
        returns (RingBackedLiqHook h, PoolKey memory k)
    {
        // nonce changes the CREATE2 deployer via a harmless factory object for independent pools.
        bytes memory args = abi.encode(pm, few, dex, address(this));
        bytes32 salt;
        address predicted;
        (salt, predicted) = HookMiner.mine(address(this), type(RingBackedLiqHook).creationCode, args, 0x2ac0, 300_000);
        if (nonce != 0) {
            uint256 candidate = uint256(salt) + nonce;
            bytes32 initHash = keccak256(bytes.concat(type(RingBackedLiqHook).creationCode, args));
            while (true) {
                predicted = address(
                    uint160(
                        uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(candidate), initHash)))
                    )
                );
                if (uint160(predicted) & 0x3fff == 0x2ac0 && predicted.code.length == 0) {
                    salt = bytes32(candidate);
                    break;
                }
                ++candidate;
            }
        }
        h = new RingBackedLiqHook{salt: salt}(pm, few, dex, address(this));
        k = PoolKey(Currency.wrap(a), Currency.wrap(b), 0, spacing, IHooks(address(h)));
        h.initializePool(k, route, initialPrice);
    }

    function _fundBuffers(RingBackedLiqHook h) internal {
        IERC20(a).approve(address(h), 1_000_000);
        IERC20(b).approve(address(h), 1_000_000);
        h.fundRounding(Currency.wrap(a), 1_000_000);
        h.fundRounding(Currency.wrap(b), 1_000_000);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        IERC20(a).approve(address(lp), type(uint256).max);
        IERC20(b).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), int256(100 ether), 0
            ),
            ""
        );
        h.setPoolLive(true);
    }

    function _fund(address fw, address to, uint256 amount) internal {
        address underlying = MockFewWrappedToken(fw).token();
        MockERC20(underlying).mint(address(this), amount);
        IERC20(underlying).approve(fw, amount);
        MockFewWrappedToken(fw).wrap(amount);
        require(IERC20(fw).transfer(to, amount));
    }

    function _pair(address x, address y, uint256 rx, uint256 ry) internal returns (BackingPair p) {
        p = new BackingPair(x, y);
        _fund(x, address(p), rx);
        _fund(y, address(p), ry);
        p.sync();
        dex.set(x, y, address(p));
    }

    function _params(bool forward, int256 specified) internal pure returns (SwapParams memory) {
        return SwapParams(forward, specified, forward ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }

    struct Snapshot {
        uint256 userIn;
        uint256 userOut;
        uint256 reserve0;
        uint256 reserve1;
        uint256 pm0;
        uint256 pm1;
    }

    function _snapshot(bool forward) internal view returns (Snapshot memory s) {
        s.userIn = IERC20(forward ? a : b).balanceOf(address(this));
        s.userOut = IERC20(forward ? b : a).balanceOf(address(this));
        s.reserve0 = hook.roundingReserve(Currency.wrap(a));
        s.reserve1 = hook.roundingReserve(Currency.wrap(b));
        s.pm0 = IERC20(a).balanceOf(address(pm));
        s.pm1 = IERC20(b).balanceOf(address(pm));
    }

    function _trade(bool forward, bool exactInput, uint256 size) internal {
        int256 specified = exactInput ? -SafeCast.toInt256(size) : SafeCast.toInt256(size);
        (uint256 ri, uint256 ro, RingLPPlanner.Plan memory p) = hook.quote(key, forward, specified);
        assertEq(ri == 0, ro == 0, "Ring leg is all-or-nothing");
        if (exactInput) {
            assertEq(p.amountIn, size);
        } else {
            assertEq(p.amountOut, size);
        }
        Snapshot memory s = _snapshot(forward);
        vm.recordLogs();
        BalanceDelta d =
            router.swap(key, _params(forward, specified), exactInput ? p.amountOut : p.amountIn, block.timestamp);
        _assertLPEvents(p.liquidity == 0 ? 0 : 2);
        assertEq(int256(forward ? d.amount0() : d.amount1()), -SafeCast.toInt256(p.amountIn));
        _assertCleared(p, s, forward);
    }

    function _syncTo(uint160 target) internal {
        (uint160 start,,,) = pm.getSlot0(key.toId());
        bool forward = target < start;
        uint256 amount = forward
            ? SqrtPriceMath.getAmount0Delta(target, start, expectedBaseLiquidity, true)
            : SqrtPriceMath.getAmount1Delta(start, target, expectedBaseLiquidity, true);
        BalanceDelta delta =
            router.syncPrice(key, SwapParams(forward, -SafeCast.toInt256(amount), target), 1, block.timestamp);
        assertEq(forward ? delta.amount0() : delta.amount1(), -SafeCast.toInt128(SafeCast.toInt256(amount)));
        assertEq(pm.getLiquidity(key.toId()), expectedBaseLiquidity);
    }

    function _assertLPEvents(uint256 expected) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 modifications;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(pm)
                    && logs[i].topics[0] == keccak256("ModifyLiquidity(bytes32,address,int24,int24,int256,bytes32)")
            ) ++modifications;
        }
        assertEq(modifications, expected, "JIT position add/remove count");
    }

    function _assertCleared(RingLPPlanner.Plan memory p, Snapshot memory s, bool forward) internal view {
        assertEq(s.userIn - IERC20(forward ? a : b).balanceOf(address(this)), p.amountIn);
        assertEq(IERC20(forward ? b : a).balanceOf(address(this)) - s.userOut, p.amountOut);
        (uint160 end,,,) = pm.getSlot0(key.toId());
        assertEq(end, p.end);
        assertEq(pm.getLiquidity(key.toId()), expectedBaseLiquidity);
        (uint128 remaining,,) =
            pm.getPositionInfo(key.toId(), address(hook), p.lower, p.upper, keccak256("RingBackedLiqHook.position"));
        assertEq(remaining, 0);
        assertLe(s.reserve0 - hook.roundingReserve(Currency.wrap(a)), 8);
        assertLe(s.reserve1 - hook.roundingReserve(Currency.wrap(b)), 8);
        assertEq(IERC20(a).balanceOf(address(hook)), hook.roundingReserve(Currency.wrap(a)));
        assertEq(IERC20(b).balanceOf(address(hook)), hook.roundingReserve(Currency.wrap(b)));
        // PoolManager retains the permanent base position, so its physical token balances
        // legitimately change as that position participates in the swap.
        assertEq(IERC20(fwA).balanceOf(address(hook)), 0);
        assertEq(IERC20(fwB).balanceOf(address(hook)), 0);
    }

    function test_PermissionsAndFourModes() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory first) = hook.quote(key, true, -int256(1 ether));
        assertGt(first.liquidity, 0, "first trade must exercise Ring JIT");
        assertGt(ringIn, 0);
        assertGt(ringOut, 0);
        _trade(true, true, 1 ether);
        (uint112 before0, uint112 before1,) = pair.getReserves();
        (ringIn, ringOut, first) = hook.quote(key, false, -int256(1 ether));
        assertEq(first.liquidity, 0, "opposite trade demonstrates base-only fallback");
        assertEq(ringIn, 0);
        assertEq(ringOut, 0);
        _trade(false, true, 1 ether);
        (uint112 after0, uint112 after1,) = pair.getReserves();
        assertEq(after0, before0, "fallback must not touch Ring reserve0");
        assertEq(after1, before1, "fallback must not touch Ring reserve1");
        _trade(true, false, 1 ether);
        _trade(false, false, 1 ether);
    }

    function test_FullRangeBasePositionCanBeAddedAndRemoved() public {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        IERC20(a).approve(address(lp), type(uint256).max);
        IERC20(b).approve(address(lp), type(uint256).max);
        ModifyLiquidityParams memory params = ModifyLiquidityParams(
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            int256(10 ether),
            bytes32(uint256(7))
        );
        lp.modifyLiquidity(key, params, "");
        assertEq(pm.getLiquidity(key.toId()), 110 ether);
        params.liquidityDelta = -int256(10 ether);
        lp.modifyLiquidity(key, params, "");
        assertEq(pm.getLiquidity(key.toId()), 100 ether);
    }

    function test_SepoliaRatioUsesRingJITInsteadOfShallowBaseFallback() public {
        _resetRingReserves(1_000_000 ether, 1 ether);
        address[] memory route = new address[](2);
        route[0] = fwA;
        route[1] = fwB;
        (hook, key) = _deployAt(route, 60, 3, 79_228_162_514_264_337_593_543_950);
        IERC20(a).approve(address(hook), 1_000_000);
        IERC20(b).approve(address(hook), 1_000_000);
        hook.fundRounding(Currency.wrap(a), 1_000_000);
        hook.fundRounding(Currency.wrap(b), 1_000_000);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        IERC20(a).approve(address(lp), type(uint256).max);
        IERC20(b).approve(address(lp), type(uint256).max);
        expectedBaseLiquidity = 10_000_000_000_000_000_000;
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams(
                TickMath.minUsableTick(key.tickSpacing),
                TickMath.maxUsableTick(key.tickSpacing),
                int256(uint256(expectedBaseLiquidity)),
                0
            ),
            ""
        );
        hook.setPoolLive(true);
        (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(30_000 ether));
        assertGt(ringIn, 0);
        assertGt(ringOut, 0);
        assertGt(p.liquidity, 0);
        assertGt(p.amountOut, 29_000_000_000_000_000);
        _trade(true, true, 30_000 ether);
    }

    function test_CannotGoLiveWithoutBaseLiquidity() public {
        address[] memory route = new address[](2);
        route[0] = fwA;
        route[1] = fwB;
        (RingBackedLiqHook empty,) = _deploy(route, 60, 2);
        IERC20(a).approve(address(empty), 1_000_000);
        IERC20(b).approve(address(empty), 1_000_000);
        empty.fundRounding(Currency.wrap(a), 1_000_000);
        empty.fundRounding(Currency.wrap(b), 1_000_000);
        vm.expectRevert(RingBackedLiqHook.UnexpectedLiquidity.selector);
        empty.setPoolLive(true);
    }

    function testFuzz_RealLPClearsAtBoundedCost(bool forward, bool exactInput, uint64 raw) public {
        _trade(forward, exactInput, bound(uint256(raw), 1e6, 10 ether));
    }

    function test_RepeatedSwapsAndBitmapBoundary() public {
        // Alternating trades cross the zero bitmap-word boundary without accumulating stale spot drift.
        for (uint256 i; i < 8; ++i) {
            _trade(i % 2 == 0, i % 3 == 0, 1 ether);
        }
    }

    function test_TickSpacingOne() public {
        address[] memory route = new address[](2);
        route[0] = fwA;
        route[1] = fwB;
        (hook, key) = _deploy(route, 1, 1);
        _fundBuffers(hook);
        _trade(true, true, 1 ether);
        _trade(false, false, 1 ether);
    }

    function test_MultihopBothDirections() public {
        address c = address(new MockERC20("C", "C", 18));
        address fwC = address(few.create(c));
        _pair(fwA, fwC, 10_000 ether, 30_000 ether);
        _pair(fwC, fwB, 10_000 ether, 20_000 ether);
        address[] memory route = new address[](3);
        route[0] = fwA;
        route[1] = fwC;
        route[2] = fwB;
        (hook, key) = _deployAt(route, 60, 1, 194_068_571_418_249_185_253_397_768_292);
        _fundBuffers(hook);
        _trade(true, true, 1 ether);
        _trade(false, true, 1 ether);
        _trade(true, false, 1 ether);
        _trade(false, false, 1 ether);
        assertEq(IERC20(fwC).balanceOf(address(hook)), 0);
    }

    function test_SlippageRevertsRingAndLPAtomically() public {
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, -int256(1 ether));
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint160 beforePrice,,,) = pm.getSlot0(key.toId());
        uint256 beforeUser = IERC20(a).balanceOf(address(this));
        vm.expectRevert(RingLPRouter.SlippageExceeded.selector);
        router.swap(key, _params(true, -int256(1 ether)), p.amountOut + 1, block.timestamp);
        (uint112 a0, uint112 a1,) = pair.getReserves();
        assertEq(a0, r0);
        assertEq(a1, r1);
        (uint160 afterPrice,,,) = pm.getSlot0(key.toId());
        assertEq(afterPrice, beforePrice);
        assertEq(IERC20(a).balanceOf(address(this)), beforeUser);
        assertEq(pm.getLiquidity(key.toId()), 100 ether);
    }

    function test_PauseBufferAndExternalLPRejected() public {
        hook.setPoolLive(false);
        assertEq(hook.getIndicativeQuote(key, true, -int256(1 ether), ""), 0);
        vm.expectRevert();
        router.swap(key, _params(true, -int256(1 ether)), 1, block.timestamp);
        hook.setPoolLive(true);
        hook.withdrawRounding(Currency.wrap(a), 999_990, address(this));
        assertEq(hook.getIndicativeQuote(key, true, -int256(1 ether), ""), 0);
        vm.expectRevert();
        router.swap(key, _params(true, -int256(1 ether)), 1, block.timestamp);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        vm.expectRevert();
        lp.modifyLiquidity(key, ModifyLiquidityParams(-60, 60, 1000, 0), "");
    }

    function test_ExpiryPriceLimitAndNoPrefunding() public {
        vm.warp(100);
        vm.expectRevert(RingLPRouter.Expired.selector);
        router.swap(key, _params(true, -int256(1 ether)), 1, 99);
        vm.expectRevert();
        router.swap(key, SwapParams(true, -int256(1 ether), TickMath.getSqrtPriceAtTick(100_000)), 1, 100);
        PoolSwapTest postpay = new PoolSwapTest(pm);
        IERC20(a).approve(address(postpay), type(uint256).max);
        postpay.swap(key, _params(true, -int256(1 ether)), PoolSwapTest.TestSettings(false, false), "");
        _trade(true, true, 1 ether);
    }

    function test_PairCannotReenterRouter() public {
        pair.setCallback(
            address(router), abi.encodeCall(router.swap, (key, _params(true, -int256(1 ether)), 1, block.timestamp))
        );
        _trade(true, true, 1 ether);
    }

    function testFuzz_SequenceKeepsPositionsAndBuffersSound(uint256 seed) public {
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            _trade(i % 2 == 0, seed & 2 != 0, bound(seed >> 2, 1e6, 1 ether));
        }
    }

    function _resetRingReserves(uint256 reserveA, uint256 reserveB) internal {
        uint256 oldA = IERC20(fwA).balanceOf(address(pair));
        uint256 oldB = IERC20(fwB).balanceOf(address(pair));
        vm.prank(address(pair));
        require(IERC20(fwA).transfer(address(this), oldA));
        vm.prank(address(pair));
        require(IERC20(fwB).transfer(address(this), oldB));
        _fund(fwA, address(pair), reserveA);
        _fund(fwB, address(pair), reserveB);
        pair.sync();
    }

    function test_DifferentRawAmountsAllModes() public {
        _resetRingReserves(5000 ether, 10_000 ether);
        vm.expectRevert(RingBackedLiqHook.QuoteDeviationExceeded.selector);
        hook.quote(key, true, -int256(1 ether));
        assertEq(hook.getIndicativeQuote(key, true, -int256(1 ether), ""), 0);
        _syncTo(112_045_541_949_572_279_837_463_876_454);
        _trade(true, true, 1 ether);
        _trade(false, true, 2 ether);
        _trade(true, false, 2 ether);
        _trade(false, false, 1 ether);
    }

    function test_ExactOutputRefundsUnusedPrepayment() public {
        (,, RingLPPlanner.Plan memory p) = hook.quote(key, true, int256(1 ether));
        Snapshot memory s = _snapshot(true);
        vm.recordLogs();
        router.swap(key, _params(true, int256(1 ether)), p.amountIn + 1 ether, block.timestamp);
        _assertLPEvents(p.liquidity == 0 ? 0 : 2);
        _assertCleared(p, s, true);
        assertEq(IERC20(a).balanceOf(address(router)), 0);
    }

    function test_PairCannotReenterHookOrWithdrawRounding() public {
        pair.setCallback(address(pm), abi.encodeCall(pm.swap, (key, _params(true, -int256(1 ether)), bytes(""))));
        _trade(true, true, 1 ether);
        hook.transferOwnership(address(pair));
        vm.prank(address(pair));
        hook.acceptOwnership();
        pair.setCallback(
            address(hook), abi.encodeCall(hook.withdrawRounding, (key.currency0, uint256(1_000_000), address(pair)))
        );
        _trade(false, false, 1 ether);
    }

    function test_ProtocolFeeTinyAndOversizedQuotesRejected() public {
        assertEq(hook.getIndicativeQuote(key, true, -1, ""), 0);
        assertEq(hook.getIndicativeQuote(key, true, type(int256).min, ""), 0);
        assertEq(hook.getIndicativeQuote(key, true, -int256(uint256(type(uint96).max) + 1), ""), 0);
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 1000);
        assertEq(hook.getIndicativeQuote(key, true, -int256(1 ether), ""), 0);
        vm.expectRevert();
        router.swap(key, _params(true, -int256(1 ether)), 1, block.timestamp);
    }

    function test_StaleQuoteAndUnfundedOutputDoNotSpendBuffer() public {
        (,, RingLPPlanner.Plan memory old) = hook.quote(key, true, -int256(1 ether));
        _trade(true, true, 10 ether);
        uint256 r0 = hook.roundingReserve(key.currency0);
        uint256 r1 = hook.roundingReserve(key.currency1);
        vm.expectRevert(RingLPRouter.SlippageExceeded.selector);
        router.swap(key, _params(true, -int256(1 ether)), old.amountOut, block.timestamp);
        assertEq(hook.roundingReserve(key.currency0), r0);
        assertEq(hook.roundingReserve(key.currency1), r1);
        vm.expectRevert();
        router.swap(key, _params(true, int256(1_000_000 ether)), 1 ether, block.timestamp);
        assertEq(hook.roundingReserve(key.currency0), r0);
        assertEq(hook.roundingReserve(key.currency1), r1);
    }

    function test_InitializationAndAdministrationStayOwnerGated() public {
        vm.expectRevert(RingBackedLiqHook.RenounceOwnershipDisabled.selector);
        hook.renounceOwnership();
        address outsider = address(0xbeef);
        vm.prank(outsider);
        vm.expectRevert();
        hook.setPoolLive(false);
        vm.prank(outsider);
        vm.expectRevert();
        hook.withdrawRounding(key.currency0, 1, outsider);
        vm.expectRevert(RingLPRouter.UnauthorizedCallback.selector);
        router.unlockCallback("");
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        pm.initialize(other, 79228162514264337593543950336);
        other = key;
        other.tickSpacing = 1;
        vm.expectRevert();
        pm.initialize(other, 79228162514264337593543950336);
        (address[] memory path,) = hook.getRoute();
        vm.expectRevert();
        hook.initializePool(key, path, 79228162514264337593543950336);
    }

    function test_SyncPriceKeepsOrdinaryHookPermissions() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);

        _fund(fwA, address(pair), 10_000 ether);
        pair.sync();
        (uint256 deviationBps, uint256 allowedBps) = hook.getSpotDeviationBps(true);
        assertGt(deviationBps, allowedBps);
        vm.expectRevert(RingBackedLiqHook.QuoteDeviationExceeded.selector);
        hook.quote(key, true, -int256(1 ether));

        _syncTo(56_022_770_974_786_139_918_731_938_227);
        (deviationBps, allowedBps) = hook.getSpotDeviationBps(true);
        assertLe(deviationBps, allowedBps);
        (,, RingLPPlanner.Plan memory plan) = hook.quote(key, true, -int256(1 ether));
        assertEq(plan.amountIn, 1 ether);
        _trade(true, true, 1 ether);
    }
}
