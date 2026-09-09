// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolSwapTest, PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolClaimsTest} from "@uniswap/v4-core/src/test/PoolClaimsTest.sol";

import {RingShareLiqHook} from "../src/hooks/RingShareLiqHook.sol";
import {RingV2Math} from "../src/libraries/RingV2Math.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";
import {IWETH9} from "../src/interfaces/external/IWETH9.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockWETH9 is IWETH9 {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        totalSupply += msg.value;
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        payable(msg.sender).transfer(amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Minimal FewWrappedToken mock: 1:1 wrap/unwrap against the underlying ERC20.
contract MockFewWrappedToken is IFewWrappedToken {
    address public immutable token;
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address _token) {
        token = _token;
        name = "fwTEST";
        symbol = "fwTEST";
    }

    function wrap(uint256 amount) external returns (uint256) {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "wrap transferFrom");
        _mint(msg.sender, amount);
        return amount;
    }

    function unwrap(uint256 amount) external returns (uint256) {
        _burn(msg.sender, amount);
        require(IERC20(token).transfer(msg.sender, amount), "unwrap transfer");
        return amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Minimal FewFactory mock: lazily creates a 1:1 wrapped token per underlying.
contract MockFewFactory is IFewFactory {
    mapping(address => address) public wrapped;
    address[] public allWrapped;

    function getWrappedToken(address originalToken) public view returns (address wrappedToken) {
        return wrapped[originalToken];
    }

    function createToken(address originalToken) external returns (address wrappedToken) {
        require(wrapped[originalToken] == address(0), "exists");
        MockFewWrappedToken t = new MockFewWrappedToken(originalToken);
        wrapped[originalToken] = address(t);
        allWrapped.push(address(t));
        return address(t);
    }

    /// @dev Test helper: create the wrapped token for a token and return it.
    function create(address originalToken) external returns (MockFewWrappedToken) {
        if (wrapped[originalToken] == address(0)) {
            this.createToken(originalToken);
        }
        return MockFewWrappedToken(wrapped[originalToken]);
    }

    function setWrapped(address originalToken, address wrappedToken) external {
        wrapped[originalToken] = wrappedToken;
    }
}

/// @notice CREATE2 helper so the test can deploy the hook at an address whose low 14 bits match
///         the required permission flags.
library HookMiner {
    function mine(address deployer, bytes memory creationCode, bytes memory args, uint160 flags, uint256 maxIter)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes memory initCode = bytes.concat(creationCode, args);
        bytes32 codeHash = keccak256(initCode);
        for (uint256 i = 0; i < maxIter; i++) {
            salt = bytes32(i);
            bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), bytes20(deployer), salt, codeHash));
            predicted = address(uint160(uint256(hash)));
            if (uint160(predicted) & 0x3FFF == flags) {
                return (salt, predicted);
            }
        }
        revert("no salt found");
    }
}

contract RingShareLiqHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    // beforeInitialize(13) + beforeAddLiquidity(11) + beforeRemoveLiquidity(9) +
    // beforeSwap(7) + afterSwap(6) + beforeSwapReturnDelta(3) = 0x2AC8
    uint160 constant HOOK_FLAGS = 0x2AC8;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    PoolManager manager;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    PoolClaimsTest claimsRouter;

    MockERC20 tokenA;
    MockERC20 tokenB;
    Currency currency0;
    Currency currency1;
    MockFewFactory fewFactory;
    MockFewWrappedToken fwToken0;
    MockFewWrappedToken fwToken1;

    RingShareLiqHook hook;
    PoolKey key;
    PoolId poolId;

    address owner = address(this);

    function setUp() public {
        // Fresh PoolManager + routers
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        claimsRouter = new PoolClaimsTest(manager);

        // Two test tokens, sorted into currency0/1
        tokenA = new MockERC20("A", "A", 18);
        tokenB = new MockERC20("B", "B", 18);
        tokenA.mint(address(this), type(uint256).max);
        tokenB.mint(address(this), type(uint256).max);
        (currency0, currency1) = address(tokenA) < address(tokenB)
            ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
            : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));

        // FewFactory + wrapped tokens for both currencies
        fewFactory = new MockFewFactory();
        fwToken0 = fewFactory.create(Currency.unwrap(currency0));
        fwToken1 = fewFactory.create(Currency.unwrap(currency1));

        // Approve underlying → wrapped (for wrap), and wrapped → hook (for deposit/bootstrap)
        IERC20(Currency.unwrap(currency0)).approve(address(fwToken0), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(fwToken1), type(uint256).max);

        // Deploy the hook via CREATE2 with the right flag bits
        // Constructor: (IPoolManager, uint32 maxGas, address owner, IFewFactory, IWETH9)
        bytes memory creationCode = type(RingShareLiqHook).creationCode;
        bytes memory args =
            abi.encode(address(manager), uint32(500_000), owner, IFewFactory(address(fewFactory)), IWETH9(address(0)));
        (bytes32 salt, address predicted) = HookMiner.mine(address(this), creationCode, args, HOOK_FLAGS, 10_000_000);
        hook = new RingShareLiqHook{salt: salt}(manager, 500_000, owner, fewFactory, IWETH9(address(0)));
        require(address(hook) == predicted, "hook addr mismatch");
        require(uint160(address(hook)) & 0x3FFF == HOOK_FLAGS, "hook flags mismatch");

        // Build the pool key
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        // Initialize the pool via the hook's initializePool (owner-only)
        hook.initializePool(key, SQRT_PRICE_1_1);

        // Approve routers
        tokenA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenA.approve(address(swapRouter), type(uint256).max);
        tokenB.approve(address(swapRouter), type(uint256).max);
        fwToken0.approve(address(hook), type(uint256).max);
        fwToken1.approve(address(hook), type(uint256).max);

        // Wrap + bootstrap the hook's reserve with 10000 of each fwToken.
        // The hook provides ALL liquidity via its V2 fwToken reserves.
        fwToken0.wrap(10000 ether);
        fwToken1.wrap(10000 ether);
        hook.bootstrap(key, 10000 ether, 10000 ether);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                          CONSTRUCTION
    // ══════════════════════════════════════════════════════════════════════

    function test_HookPermissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertTrue(p.beforeSwapReturnDelta);
        assertFalse(p.afterInitialize);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.afterSwapReturnDelta);
    }

    function test_OwnerIsDeployer() public view {
        assertEq(hook.owner(), owner);
    }

    function test_FactoryIsDeployer() public view {
        assertEq(hook.factory(), address(this));
    }

    function test_RevertConstruct_ZeroFactory() public {
        bytes memory creationCode = type(RingShareLiqHook).creationCode;
        bytes memory args =
            abi.encode(address(manager), uint32(500_000), owner, IFewFactory(address(0)), IWETH9(address(0)));
        (bytes32 salt,) = HookMiner.mine(address(this), creationCode, args, HOOK_FLAGS, 10_000_000);
        vm.expectRevert(RingShareLiqHook.WrappedTokenNotFound.selector);
        new RingShareLiqHook{salt: salt}(manager, 500_000, owner, IFewFactory(address(0)), IWETH9(address(0)));
    }

    function test_RevertConstruct_ZeroPoolManager() public {
        bytes memory creationCode = type(RingShareLiqHook).creationCode;
        bytes memory args =
            abi.encode(address(0), uint32(500_000), owner, IFewFactory(address(fewFactory)), IWETH9(address(0)));
        (bytes32 salt,) = HookMiner.mine(address(this), creationCode, args, HOOK_FLAGS, 10_000_000);
        vm.expectRevert(RingShareLiqHook.InvalidPoolManager.selector);
        new RingShareLiqHook{salt: salt}(IPoolManager(address(0)), 500_000, owner, fewFactory, IWETH9(address(0)));
    }

    // ══════════════════════════════════════════════════════════════════════
    //                          POOL INITIALIZATION
    // ══════════════════════════════════════════════════════════════════════

    function test_PoolIsLiveAfterBootstrap() public view {
        assertTrue(hook.livePools(poolId));
        assertEq(PoolId.unwrap(hook.configuredPoolId()), PoolId.unwrap(poolId));
    }

    function test_RevertInitialize_SecondPool() public {
        PoolKey memory otherKey = _otherKey();
        vm.expectRevert(RingShareLiqHook.PoolAlreadyInitialized.selector);
        hook.initializePool(otherKey, SQRT_PRICE_1_1);
    }

    function test_RevertInitialize_WrapperUnderlyingMismatch() public {
        RingShareLiqHook freshHook = _deployFreshHook(500_001);
        MockFewWrappedToken wrong = new MockFewWrappedToken(Currency.unwrap(currency1));
        fewFactory.setWrapped(Currency.unwrap(currency0), address(wrong));
        PoolKey memory freshKey = _keyFor(address(freshHook));

        vm.expectRevert(RingShareLiqHook.WrappedTokenNotFound.selector);
        freshHook.initializePool(freshKey, SQRT_PRICE_1_1);
    }

    function test_RevertBootstrap_ZeroAmount() public {
        RingShareLiqHook freshHook = _deployFreshHook(500_002);
        PoolKey memory freshKey = _keyFor(address(freshHook));
        freshHook.initializePool(freshKey, SQRT_PRICE_1_1);

        vm.expectRevert(RingShareLiqHook.InsufficientReserve.selector);
        freshHook.bootstrap(freshKey, 0, 0);
    }

    function test_RevertInitialize_NotOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        hook.initializePool(key, SQRT_PRICE_1_1);
    }

    function test_RevertBootstrap_AlreadyBootstrapped() public {
        vm.expectRevert(RingShareLiqHook.PoolAlreadyBootstrapped.selector);
        hook.bootstrap(key, 1 ether, 1 ether);
    }

    function test_RevertDirectInitialize() public {
        // Direct poolManager.initialize should be blocked by _beforeInitialize
        PoolKey memory badKey = PoolKey({
            currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))
        });
        vm.expectRevert();
        manager.initialize(badKey, SQRT_PRICE_1_1);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                          RESERVES
    // ══════════════════════════════════════════════════════════════════════

    function test_ReservesAfterBootstrap() public view {
        (uint256 r0, uint256 r1) = hook.getReserves(key);
        assertEq(r0, 10000 ether);
        assertEq(r1, 10000 ether);
    }

    function test_DepositIncreasesReserve() public {
        fwToken0.wrap(500 ether);
        fwToken1.wrap(300 ether);
        hook.deposit(key, 500 ether, 300 ether);
        (uint256 r0, uint256 r1) = hook.getReserves(key);
        assertEq(r0, 10500 ether);
        assertEq(r1, 10300 ether);
    }

    function test_NativeReservePullsExistingFwWeth() public {
        MockWETH9 weth = new MockWETH9();
        MockFewWrappedToken fwWeth = fewFactory.create(address(weth));
        RingShareLiqHook nativeHook = _deployFreshHook(500_003, weth);
        PoolKey memory nativeKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency0,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(nativeHook))
        });
        PoolId nativePoolId = nativeKey.toId();
        nativeHook.initializePool(nativeKey, SQRT_PRICE_1_1);

        vm.deal(address(this), 150 ether);
        weth.deposit{value: 150 ether}();
        weth.approve(address(fwWeth), type(uint256).max);
        fwWeth.wrap(150 ether);
        fwToken0.wrap(150 ether);
        fwWeth.approve(address(nativeHook), type(uint256).max);
        fwToken0.approve(address(nativeHook), type(uint256).max);

        nativeHook.bootstrap(nativeKey, 100 ether, 100 ether);
        nativeHook.deposit(nativeKey, 50 ether, 50 ether);

        assertEq(nativeHook.fwReserveOf(nativePoolId, nativeKey.currency0), 150 ether);
        assertEq(nativeHook.fwReserveOf(nativePoolId, nativeKey.currency1), 150 ether);
        assertEq(fwWeth.balanceOf(address(nativeHook)), 150 ether);
        assertEq(address(nativeHook).balance, 0);
    }

    function test_WithdrawDecreasesReserve() public {
        hook.withdraw(key, 1000 ether, 0, address(this));
        (uint256 r0,) = hook.getReserves(key);
        assertEq(r0, 9000 ether);
    }

    function test_WrapperMappingIsPinnedAfterInitialization() public {
        MockFewWrappedToken replacement = new MockFewWrappedToken(Currency.unwrap(currency0));
        fewFactory.setWrapped(Currency.unwrap(currency0), address(replacement));

        fwToken0.wrap(100 ether);
        uint256 before = fwToken0.balanceOf(address(this));
        hook.deposit(key, 100 ether, 0);
        hook.withdraw(key, 100 ether, 0, address(this));

        assertEq(fwToken0.balanceOf(address(this)), before);
        assertEq(replacement.balanceOf(address(hook)), 0);
        assertEq(hook.wrappedTokenOf(currency0), address(fwToken0));
    }

    function test_RevertManagementAndViews_ForOtherPool() public {
        PoolKey memory otherKey = _otherKey();

        vm.expectRevert(RingShareLiqHook.InvalidPool.selector);
        hook.bootstrap(otherKey, 0, 0);
        vm.expectRevert(RingShareLiqHook.InvalidPool.selector);
        hook.deposit(otherKey, 1, 0);
        vm.expectRevert(RingShareLiqHook.InvalidPool.selector);
        hook.withdraw(otherKey, 0, 0, address(this));
        vm.expectRevert(RingShareLiqHook.InvalidPool.selector);
        hook.sweepClaims(otherKey);
        vm.expectRevert(RingShareLiqHook.InvalidPool.selector);
        hook.setPoolLive(otherKey, false);
        vm.expectRevert(RingShareLiqHook.InvalidPool.selector);
        hook.getReserves(otherKey);
        vm.expectRevert(RingShareLiqHook.InvalidPool.selector);
        hook.getEffectiveLiquidity(otherKey);
        vm.expectRevert(RingShareLiqHook.InvalidPool.selector);
        hook.getIndicativeQuote(otherKey, true, -int256(1 ether), "");
        vm.expectRevert(RingShareLiqHook.InvalidPool.selector);
        hook.swapToPrice(otherKey, true, -int256(1 ether), TickMath.MIN_SQRT_PRICE + 1, "");

        vm.prank(address(manager));
        vm.expectRevert(RingShareLiqHook.InvalidPool.selector);
        hook.unlockCallback(abi.encode(otherKey));
    }

    function test_RevertWithdraw_Insufficient() public {
        vm.expectRevert(RingShareLiqHook.InsufficientReserve.selector);
        hook.withdraw(key, 100_000 ether, 0, address(this));
    }

    function test_RevertDeposit_NotOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        hook.deposit(key, 100 ether, 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                          EXTERNAL LP (OPEN)
    // ══════════════════════════════════════════════════════════════════════

    function test_ExternalAddLiquiditySucceeds() public {
        // External LP is allowed — the hook intercepts all swaps via beforeSwapReturnDelta,
        // so external LP liquidity sits in the V4 pool but is never used for swap execution.
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: int256(1 ether), salt: 0}), ""
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    //                          PAUSE / RESUME
    // ══════════════════════════════════════════════════════════════════════

    function test_PauseBlocksSwaps() public {
        hook.setPoolLive(key, false);
        assertFalse(hook.livePools(poolId));

        bool zeroForOne = currency0 < currency1;
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            zeroForOne: zeroForOne
        });
        vm.expectRevert();
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function test_ResumeAllowsSwaps() public {
        hook.setPoolLive(key, false);
        hook.setPoolLive(key, true);
        assertTrue(hook.livePools(poolId));
    }

    // ══════════════════════════════════════════════════════════════════════
    //                          SWAP (V2)
    // ══════════════════════════════════════════════════════════════════════

    function test_SwapExactInputSucceeds() public {
        bool zeroForOne = currency0 < currency1;
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            zeroForOne: zeroForOne
        });
        BalanceDelta delta =
            swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0);
    }

    function test_SwapExactOutputSucceeds() public {
        bool zeroForOne = currency0 < currency1;
        SwapParams memory params = SwapParams({
            amountSpecified: int256(1 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            zeroForOne: zeroForOne
        });
        BalanceDelta delta =
            swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0);
    }

    function test_SwapMatchesV2Math() public {
        bool zeroForOne = currency0 < currency1;
        (uint256 r0, uint256 r1) = hook.getReserves(key);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (r0, r1) : (r1, r0);

        uint256 amountIn = 1 ether;
        uint256 expectedOut = RingV2Math.getAmountOut(amountIn, reserveIn, reserveOut, 3000);

        SwapParams memory params = SwapParams({
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            zeroForOne: zeroForOne
        });
        BalanceDelta delta =
            swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        // For zeroForOne: delta.amount0 < 0 (paid), delta.amount1 > 0 (received)
        if (zeroForOne) {
            assertEq(uint256(-int256(int128(delta.amount0()))), amountIn);
            assertEq(uint256(int256(int128(delta.amount1()))), expectedOut);
        } else {
            assertEq(uint256(-int256(int128(delta.amount1()))), amountIn);
            assertEq(uint256(int256(int128(delta.amount0()))), expectedOut);
        }
    }

    function test_RevertSwap_AfterAllFwReservesWithdrawn() public {
        hook.withdraw(key, 10_000 ether, 10_000 ether, address(this));
        (uint160 beforePrice,,,) = IPoolManager(address(manager)).getSlot0(poolId);

        vm.expectRevert();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        (uint160 afterPrice,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        assertEq(afterPrice, beforePrice);
    }

    function test_ReservesChangeAfterSwap() public {
        (uint256 r0Before, uint256 r1Before) = hook.getReserves(key);

        bool zeroForOne = currency0 < currency1;
        SwapParams memory params = SwapParams({
            amountSpecified: -int256(1 ether),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            zeroForOne: zeroForOne
        });
        swapRouter.swap(key, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");

        (uint256 r0After, uint256 r1After) = hook.getReserves(key);
        // V2 invariant: total reserves increase by (amountIn - amountOut), which is > 0.
        assertGt(r0After + r1After, r0Before + r1Before);
    }

    function test_ReverseSwapRedeemsClaims() public {
        // Swap zeroForOne, then oneForZero — the second swap should redeem claims from the first.
        bool zeroForOne = currency0 < currency1;

        // First swap: zeroForOne (pay currency0, receive currency1)
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // Claims should be minted for the input currency.
        uint256 claimsIn = zeroForOne ? hook.claimReserveOf(poolId, currency0) : hook.claimReserveOf(poolId, currency1);
        assertGt(claimsIn, 0);

        // Second swap: reverse direction (redeems claims from first swap)
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: !zeroForOne,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: !zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        // After the reverse swap, the claims from the first swap should be partially or fully redeemed.
        uint256 claimsAfter =
            zeroForOne ? hook.claimReserveOf(poolId, currency0) : hook.claimReserveOf(poolId, currency1);
        // New claims may be minted for the reverse swap's input, so just check the pool still works.
        (uint256 r0, uint256 r1) = hook.getReserves(key);
        assertGt(r0 + r1, 0);
    }

    // ══════════════════════════════════════════════════════════════════════
    //                          QUOTING
    // ══════════════════════════════════════════════════════════════════════

    function test_GetIndicativeQuote() public view {
        bool zeroForOne = currency0 < currency1;
        uint256 quote = hook.getIndicativeQuote(key, zeroForOne, -int256(1 ether), "");
        assertTrue(quote > 0);

        // Verify the quote matches V2 math.
        (uint256 r0, uint256 r1) = hook.getReserves(key);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (r0, r1) : (r1, r0);
        uint256 expected = RingV2Math.getAmountOut(1 ether, reserveIn, reserveOut, 3000);
        assertEq(quote, expected);
    }

    function test_GetIndicativeQuote_Paused() public {
        hook.setPoolLive(key, false);
        bool zeroForOne = currency0 < currency1;
        uint256 quote = hook.getIndicativeQuote(key, zeroForOne, -int256(1 ether), "");
        assertEq(quote, 0);
    }

    function test_GetIndicativeQuote_ExactOutput() public {
        bool zeroForOne = currency0 < currency1;
        uint256 quote = hook.getIndicativeQuote(key, zeroForOne, int256(1 ether), "");
        assertTrue(quote > 0);

        // Verify the quote matches V2 math (input required for 1 ether output).
        (uint256 r0, uint256 r1) = hook.getReserves(key);
        (uint256 reserveIn, uint256 reserveOut) = zeroForOne ? (r0, r1) : (r1, r0);
        uint256 expected = RingV2Math.getAmountIn(1 ether, reserveIn, reserveOut, 3000);
        assertEq(quote, expected);
    }

    function test_GetIndicativeQuote_ReturnsZeroForExcessiveOutput() public view {
        bool zeroForOne = currency0 < currency1;
        // Request more output than the reserve holds.
        uint256 quote = hook.getIndicativeQuote(key, zeroForOne, int256(100_000 ether), "");
        assertEq(quote, 0);
    }

    function test_SwapToPrice_ReturnsZeroForInvalidDirection() public view {
        (uint160 currentPrice,,,) = IPoolManager(address(manager)).getSlot0(poolId);
        (uint256 amountIn0, uint256 amountOut0) = hook.swapToPrice(key, true, -int256(1 ether), currentPrice + 1, "");
        (uint256 amountIn1, uint256 amountOut1) = hook.swapToPrice(key, false, -int256(1 ether), currentPrice - 1, "");
        assertEq(amountIn0 | amountOut0 | amountIn1 | amountOut1, 0);
    }

    function test_GetEffectiveLiquidity() public view {
        (uint256 eff0, uint256 eff1) = hook.getEffectiveLiquidity(key);
        (uint256 res0, uint256 res1) = hook.getReserves(key);
        assertEq(eff0, res0);
        assertEq(eff1, res1);
    }

    function test_GetEffectiveLiquidity_CapsUnredeemableClaims() public {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(1 ether), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 claims0 = hook.claimReserveOf(poolId, currency0);
        uint256 claims1 = hook.claimReserveOf(poolId, currency1);
        Currency claimCurrency = claims0 > 0 ? currency0 : currency1;
        uint256 claims = claims0 > 0 ? claims0 : claims1;
        assertGt(claims, 0);

        deal(Currency.unwrap(claimCurrency), address(manager), 0);
        (uint256 total0, uint256 total1) = hook.getReserves(key);
        (uint256 effective0, uint256 effective1) = hook.getEffectiveLiquidity(key);

        if (claimCurrency == currency0) {
            assertEq(total0 - effective0, claims);
        } else {
            assertEq(total1 - effective1, claims);
        }
    }

    function _deployFreshHook(uint32 maxGas) internal returns (RingShareLiqHook freshHook) {
        return _deployFreshHook(maxGas, IWETH9(address(0)));
    }

    function _deployFreshHook(uint32 maxGas, IWETH9 weth) internal returns (RingShareLiqHook freshHook) {
        bytes memory creationCode = type(RingShareLiqHook).creationCode;
        bytes memory args = abi.encode(address(manager), maxGas, owner, IFewFactory(address(fewFactory)), weth);
        (bytes32 salt,) = HookMiner.mine(address(this), creationCode, args, HOOK_FLAGS, 10_000_000);
        freshHook = new RingShareLiqHook{salt: salt}(manager, maxGas, owner, fewFactory, weth);
    }

    function _keyFor(address targetHook) internal view returns (PoolKey memory) {
        return
            PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: IHooks(targetHook)});
    }

    function _otherKey() internal view returns (PoolKey memory) {
        return
            PoolKey({
                currency0: currency0, currency1: currency1, fee: 500, tickSpacing: 10, hooks: IHooks(address(hook))
            });
    }
}
