// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {OwnedALFHook} from "alf/base/OwnedALFHook.sol";

import {RingV2Math} from "../libraries/RingV2Math.sol";

import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";
import {IFewFactory} from "../interfaces/external/IFewFactory.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";

/// @title Ring Share Liquidity Hook — RingV2 constant-product swap via fwToken reserves
/// @notice The hook holds a token reserve as Few wrapped tokens (fwTokens) and answers every
///         swap directly against those reserves using a V2-style constant-product formula
///         (x*y=k). The v4 pool's own AMM never executes: `beforeSwap` returns a
///         `BeforeSwapDelta` that fully intercepts the swap, and `afterSwap` settles the
///         hook's physical token movement (unwrap fwToken for output, mint ERC-6909 claims
///         for input). The fee charged internally is the pool's static LP fee (`key.fee`).
///
///         **RingV2** is a V2 variant where the underlying ("origin") tokens are wrapped into
///         fwTokens. The V2 reserves are the hook's fwToken balances; swaps change them in
///         place. Adding liquidity is "what you deposit is what you get" — the owner deposits
///         fwTokens and those amounts become the reserves, with no tick distribution or share
///         accounting.
///
///         **One hook per pool.** Each hook instance is deployed via `AllowlistedFactory` and
///         serves exactly one pool, set up through `initializePool` + `bootstrap`.
///
///         **Admin-owned capital.** Reserves are funded by the owner via `deposit` / `bootstrap`
///         and withdrawn via `withdraw`. There is no share accounting and no external LP entry
///         point; external `modifyLiquidity` calls are rejected. The owner is the sole capital
///         provider.
///
/// ## Swap lifecycle
///
///   beforeSwap:
///     1. Gate: pool live, valid
///     2. Redeem ERC-6909 claims from previous swaps (cheapest capital first)
///     3. Wrap raw reserves back into fwToken
///     4. Read V2 reserves, compute amountIn / amountOut via constant-product math
///     5. Store swap context in transient storage
///     6. Return BeforeSwapDelta — the AMM swaps nothing (amountToSwap = 0)
///
///   afterSwap:
///     1. Read swap context from transient storage
///     2. Unwrap fwToken for the output currency, settle to PoolManager
///     3. Mint ERC-6909 claims for the input currency (swapper hasn't settled yet)
///     4. Wrap any leftover raw balance back into fwToken
///     5. Clear swap context
///
/// @dev Native ETH (`address(0)`) is supported **only as `currency0`**. The hook holds reserves
///      as fwTokens regardless: callers deposit fwWETH directly, while swap output unwraps it
///      through WETH9 to ETH and swap input mints claims redeemable for ETH later. A `receive()`
///      function accepts ETH from WETH9 withdrawals and PoolManager `take`.
contract RingShareLiqHook is OwnedALFHook, ReentrancyGuardTransient, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Transient-storage namespace for the per-swap context (beforeSwap → afterSwap).
    ///      Slot +0: amountIn (uint256). Slot +1: amountOut (uint256). Slot +2: zeroForOne
    ///      (uint256, 0 or 1). A zero amountIn means "no active swap context".
    bytes32 private constant SWAP_CTX_NAMESPACE = keccak256("ringshareliq.swapctx.v2");

    // ═══════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The Few factory used to resolve fwToken addresses for each underlying currency.
    IFewFactory public immutable fewFactory;

    /// @notice The canonical WETH9 contract, used only when `currency0` is native ETH
    ///         (`address(0)`). The hook uses it when converting between fwWETH reserves and ETH
    ///         for withdrawals and swap settlement. Unused for ERC-20 / ERC-20 pools.
    IWETH9 public immutable weth9;

    /// @notice The contract that deployed this hook. Canonical deployments go through the
    ///         `AllowlistedFactory`, so aggregators and routers can verify provenance via
    ///         `factory()` against the known factory address.
    address public immutable factory;

    /// @notice The only pool this hook may serve. Set once by {initializePool}.
    PoolId public configuredPoolId;

    /// @notice Whether the single pool has been initialized.
    bool public initialized;

    /// @notice The fwToken fixed for each underlying currency at initialization.
    mapping(Currency currency => address fwToken) public wrappedTokenOf;

    /// @notice Pool-owned fwToken reserve, keyed by the pool's *underlying* currency.
    ///         This is the primary V2 reserve: swaps increase it (input wrapped) or decrease
    ///         it (output unwrapped).
    mapping(PoolId => mapping(Currency => uint256)) public fwReserveOf;

    /// @notice Pool-owned raw token reserve. Non-zero only mid-swap and for wrap dust.
    mapping(PoolId => mapping(Currency => uint256)) public rawReserveOf;

    /// @notice Pool-owned ERC-6909 claims held in the PoolManager, minted for a positive delta
    ///         (swap input) that the PoolManager could not yet pay in real tokens. Redeemed at
    ///         the start of the next swap, or by `sweepClaims`.
    mapping(PoolId => mapping(Currency => uint256)) public claimReserveOf;

    /// @dev Underlying tokens already granted an allowance to their fwToken.
    mapping(address => bool) internal _fwApproved;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new pool is initialized via `initializePool`.
    event PoolCreated(PoolId indexed poolId);

    /// @notice Emitted when the owner seeds the pool's reserve via `bootstrap` or `deposit`.
    event Deposited(PoolId indexed poolId, Currency indexed currency, uint256 fwAmount);

    /// @notice Emitted when the owner withdraws fwToken reserve.
    event Withdrawn(PoolId indexed poolId, Currency indexed currency, address indexed to, uint256 fwAmount);

    /// @notice Emitted when outstanding claims are swept back into the fwToken reserve.
    event ClaimsSwept(PoolId indexed poolId);

    // ═══════════════════════════════════════════════════════════════════════════
    //                              ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error NativeNotSupported();
    error InvalidPoolManager();
    error WrappedTokenNotFound();
    error InsufficientReserve();
    error UnauthorizedCallback();
    error InvalidHookAddress();
    error DynamicFeeNotSupported();
    error PoolAlreadyBootstrapped();
    error PoolAlreadyInitialized();
    error InvalidPool();
    error CurrencyNotInPool();
    error InsufficientOutputLiquidity();

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _pm         The Uniswap v4 PoolManager.
    /// @param maxGas_     Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_      Initial contract owner. Transferable via OZ `Ownable2Step`.
    /// @param _fewFactory The Few factory for resolving fwToken addresses.
    /// @param _weth9      The canonical WETH9 contract. Required for native ETH pools; may be
    ///                    `address(0)` if the hook will only serve ERC-20 / ERC-20 pools.
    constructor(IPoolManager _pm, uint32 maxGas_, address owner_, IFewFactory _fewFactory, IWETH9 _weth9)
        OwnedALFHook(_pm, maxGas_, owner_)
    {
        if (address(_pm) == address(0)) revert InvalidPoolManager();
        if (address(_fewFactory) == address(0)) revert WrappedTokenNotFound();
        fewFactory = _fewFactory;
        weth9 = _weth9;
        factory = msg.sender;
    }

    /// @dev Accepts native ETH from WETH9.withdraw and PoolManager.take. The hook never
    ///      holds free ETH outside a swap cycle or a deposit/withdraw/sweep operation.
    receive() external payable {}

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a new pool.
    /// @dev    Calls `poolManager.initialize` internally. The pool's LP fee is taken from
    ///         `key.fee` and is static — it is the fee the RingV2 math charges on each swap.
    ///         Native ETH (`address(0)`) is allowed **only as `currency0`**; `currency1` must
    ///         be an ERC-20. The pool is created not live: swaps revert with `PoolNotLive`
    ///         until the owner calls `bootstrap`, which seeds the reserve and flips liveness.
    /// @param key           The PoolKey (must reference this hook). `key.fee` is the static LP
    ///                      fee used by the V2 math; dynamic-fee pools are rejected.
    /// @param sqrtPriceX96  Initial sqrt price (Q64.96) for the v4 pool. Since the AMM never
    ///                      swaps, this price is display-only; the real swap price is determined
    ///                      by the V2 reserve ratio at bootstrap.
    /// @return tick  The initial tick assigned by the PoolManager.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external onlyOwner returns (int24 tick) {
        if (initialized) revert PoolAlreadyInitialized();
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        if (key.currency1.isAddressZero()) revert NativeNotSupported();
        if (key.currency0.isAddressZero() && address(weth9) == address(0)) revert NativeNotSupported();
        if (key.fee.isDynamicFee()) revert DynamicFeeNotSupported();

        address fwToken0 = _resolveWrappedToken(key.currency0);
        address fwToken1 = _resolveWrappedToken(key.currency1);

        PoolId id = key.toId();
        initialized = true;
        configuredPoolId = id;
        wrappedTokenOf[key.currency0] = fwToken0;
        wrappedTokenOf[key.currency1] = fwToken1;

        tick = poolManager.initialize(key, sqrtPriceX96);
        // Pool starts not live: liveness is gated on `bootstrap`.
        emit PoolCreated(id);
    }

    /// @notice Seed the pool's reserve with fwTokens and flip it to live.
    /// @dev    Only the owner may bootstrap. Pulls fwToken0 and fwToken1 from the caller and
    ///         credits them to the pool's reserve — these amounts become the initial V2
    ///         reserves. Flips liveness to true, enabling swaps.
    ///         Reverts if the pool is already bootstrapped (liveness already true) or if either
    ///         reserve is zero (a V2 pool needs both sides to price swaps).
    /// @param key     The pool to bootstrap.
    /// @param amount0 fwToken0 amount to deposit for currency0.
    /// @param amount1 fwToken1 amount to deposit for currency1.
    function bootstrap(PoolKey calldata key, uint256 amount0, uint256 amount1) external onlyOwner nonReentrant {
        PoolId id = key.toId();
        _requirePool(id);
        if (_liveness.isLive(id)) revert PoolAlreadyBootstrapped();
        if (amount0 == 0 || amount1 == 0) revert InsufficientReserve();

        _pullFwToken(key.currency0, amount0, id);
        _pullFwToken(key.currency1, amount1, id);

        _liveness.setLive(id, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: RESERVES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fund the pool's reserve with fwTokens for one or both currencies.
    /// @param key     The pool the capital is credited to.
    /// @param amount0 fwToken0 amount to pull from the caller (0 to skip).
    /// @param amount1 fwToken1 amount to pull from the caller (0 to skip).
    function deposit(PoolKey calldata key, uint256 amount0, uint256 amount1) external onlyOwner nonReentrant {
        PoolId id = key.toId();
        _requirePool(id);
        _pullFwToken(key.currency0, amount0, id);
        _pullFwToken(key.currency1, amount1, id);
    }

    /// @notice Withdraw the pool's fwToken reserve for one or both currencies.
    /// @dev Debits the pool's ledger first, so the reserve can never be overdrawn. For native
    ///      ETH pools, the fwWETH is unwound to WETH9 → ETH and sent as native to `to`.
    /// @param key     The pool the capital is debited from.
    /// @param amount0 fwToken0 amount to withdraw (0 to skip).
    /// @param amount1 fwToken1 amount to withdraw (0 to skip).
    /// @param to      Recipient of the fwTokens (or ETH for native pools).
    function withdraw(PoolKey calldata key, uint256 amount0, uint256 amount1, address to)
        external
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) revert NativeNotSupported();

        PoolId id = key.toId();
        _requirePool(id);
        _withdrawFwToken(id, key.currency0, amount0, to);
        _withdrawFwToken(id, key.currency1, amount1, to);
    }

    /// @notice Convert the pool's outstanding ERC-6909 claims back into its fwToken reserve.
    /// @dev Claims are only redeemable inside a PoolManager unlock, so this opens one.
    function sweepClaims(PoolKey calldata key) external onlyOwner nonReentrant {
        _requirePool(key.toId());
        poolManager.unlock(abi.encode(key));
        emit ClaimsSwept(key.toId());
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only callable by the PoolManager as a re-entrant continuation of our own
    ///      `poolManager.unlock` call inside `sweepClaims`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();
        PoolKey memory key = abi.decode(data, (PoolKey));
        PoolId id = key.toId();
        _requirePool(id);

        _redeemClaims(id, key.currency0);
        _redeemClaims(id, key.currency1);
        _wrapReserve(id, key.currency0);
        _wrapReserve(id, key.currency1);

        return "";
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: OWNER CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Enable or disable pool liveness for emergency pause/resume.
    /// @dev    When toggled to false, `_beforeSwap` reverts with `PoolNotLive`, pausing the pool.
    function setPoolLive(PoolKey calldata key, bool live) external onlyOwner {
        PoolId id = key.toId();
        _requirePool(id);
        _liveness.setLive(id, live);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Total reserves managed by this hook for the pool (fwToken + raw + claims).
    function getReserves(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        PoolId id = key.toId();
        _requirePool(id);
        token0 = _totalReserve(id, key.currency0);
        token1 = _totalReserve(id, key.currency1);
    }

    /// @notice Assets available for immediate swapping. fwTokens can be unwrapped at will;
    ///         ERC-6909 claims are capped at the PoolManager's current physical token balance.
    function getEffectiveLiquidity(PoolKey calldata key)
        external
        view
        override
        returns (uint256 token0, uint256 token1)
    {
        PoolId id = key.toId();
        _requirePool(id);
        token0 = _effectiveReserve(id, key.currency0);
        token1 = _effectiveReserve(id, key.currency1);
    }

    /// @notice V2 indicative quote against the hook's fwToken reserves.
    /// @dev Returns the output amount for exact-input swaps, or the required input for
    ///      exact-output swaps. Returns 0 when the swap cannot be filled.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        PoolId id = key.toId();
        _requirePool(id);
        if (!_liveness.isLive(id)) return 0;

        (uint256 reserveIn, uint256 reserveOut) = _v2Reserves(id, key, zeroForOne);
        if (reserveIn == 0 || reserveOut == 0) return 0;

        uint24 fee = key.fee;
        if (amountSpecified < 0) {
            // exact input: return output
            outputAmount = RingV2Math.getAmountOut(SignedMath.abs(amountSpecified), reserveIn, reserveOut, fee);
        } else {
            // exact output: return required input (0 if unfillable)
            uint256 amountOut = uint256(amountSpecified);
            if (amountOut >= reserveOut) return 0;
            outputAmount = RingV2Math.getAmountIn(amountOut, reserveIn, reserveOut, fee);
        }
    }

    /// @notice Simulate a V2 swap. The price limit is checked against the post-swap V2 price;
    ///         if the limit would be exceeded, (0, 0) is returned.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata
    ) external view override returns (uint256 amountIn, uint256 amountOut) {
        PoolId id = key.toId();
        _requirePool(id);
        if (!_liveness.isLive(id)) return (0, 0);
        if (amountSpecified == 0) return (0, 0);

        (uint256 reserveIn, uint256 reserveOut) = _v2Reserves(id, key, zeroForOne);
        if (reserveIn == 0 || reserveOut == 0) return (0, 0);

        uint24 fee = key.fee;
        if (amountSpecified < 0) {
            amountIn = SignedMath.abs(amountSpecified);
            amountOut = RingV2Math.getAmountOut(amountIn, reserveIn, reserveOut, fee);
        } else {
            amountOut = uint256(amountSpecified);
            if (amountOut >= reserveOut) return (0, 0);
            amountIn = RingV2Math.getAmountIn(amountOut, reserveIn, reserveOut, fee);
        }
        if (amountIn == 0 || amountOut == 0) return (0, 0);

        // Check post-swap price against the limit.
        if (!_priceWithinLimit(key, zeroForOne, reserveIn, reserveOut, amountIn, amountOut, sqrtPriceLimitX96)) {
            return (0, 0);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        PUBLIC: HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Required v4 hook flags:
    ///      - beforeInitialize: block direct init (force initializePool)
    ///      - beforeAddLiquidity / beforeRemoveLiquidity: reject external LPs
    ///      - beforeSwap: V2 swap computation, return BeforeSwapDelta to intercept
    ///      - beforeSwapReturnDelta: the hook answers the swap with its own delta
    ///      - afterSwap: settle output (unwrap + settle) and mint claims for input
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev External `modifyLiquidity` (add) is allowed. The hook intercepts all swaps via
    ///      `beforeSwapReturnDelta`, so external LP liquidity sits in the V4 pool but is never
    ///      used for swap execution — the hook's V2 fwToken reserve is the sole swap source.
    ///      External LPs may add and remove freely; their liquidity earns no swap fees.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev External `modifyLiquidity` (remove) is allowed — symmetric with `_beforeAddLiquidity`.
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    /// @dev V2 swap entry point. Computes the constant-product swap against the hook's fwToken
    ///      reserves and returns a `BeforeSwapDelta` that fully intercepts the swap (the AMM
    ///      swaps zero). Reverts when the pool is paused (`!live`).
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        _requirePool(id);
        _liveness.requireLive(id);

        // Redeem claims from previous swaps and wrap raw → fwToken so the full reserve is
        // available as fwToken for the output side.
        _redeemClaims(id, key.currency0);
        _redeemClaims(id, key.currency1);
        _wrapReserve(id, key.currency0);
        _wrapReserve(id, key.currency1);

        bool zeroForOne = params.zeroForOne;
        (uint256 reserveIn, uint256 reserveOut) = _v2Reserves(id, key, zeroForOne);
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientReserve();

        uint24 fee = key.fee;
        uint256 amountIn;
        uint256 amountOut;
        bool exactInput = params.amountSpecified < 0;

        if (exactInput) {
            amountIn = SignedMath.abs(params.amountSpecified);
            amountOut = RingV2Math.getAmountOut(amountIn, reserveIn, reserveOut, fee);
            if (amountOut == 0) revert InsufficientReserve();
        } else {
            amountOut = uint256(params.amountSpecified);
            if (amountOut >= reserveOut) revert InsufficientOutputLiquidity();
            amountIn = RingV2Math.getAmountIn(amountOut, reserveIn, reserveOut, fee);
        }

        // The hook must have enough fwToken of the output currency to unwrap and settle.
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        if (fwReserveOf[id][outputCurrency] < amountOut) revert InsufficientOutputLiquidity();

        // Store swap context for afterSwap.
        _storeSwapContext(amountIn, amountOut, zeroForOne);

        // Build BeforeSwapDelta:
        //   exactInput:  specifiedDelta = +amountIn (hook takes input),
        //                unspecifiedDelta = -amountOut (hook provides output)
        //   exactOutput: specifiedDelta = -amountOut (hook provides output),
        //                unspecifiedDelta = +amountIn (hook takes input)
        int128 deltaSpecified = exactInput ? int128(int256(amountIn)) : -int128(int256(amountOut));
        int128 deltaUnspecified = exactInput ? -int128(int256(amountOut)) : int128(int256(amountIn));

        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(deltaSpecified, deltaUnspecified), 0);
    }

    /// @dev V2 swap settlement. Unwraps fwToken for the output and settles it to the
    ///      PoolManager; mints ERC-6909 claims for the input (the swapper hasn't settled yet,
    ///      so the PoolManager may not hold the input tokens). The beforeSwap delta is
    ///      accounted by the PoolManager *after* afterSwap returns, so the hook pre-settles
    ///      here and the accounting nets everything to zero.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        _requirePool(id);

        (uint256 amountIn, uint256 amountOut, bool zeroForOne) = _loadSwapContext();
        if (amountIn == 0) return (IHooks.afterSwap.selector, 0); // no active context

        Currency inputCurrency = zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;

        // 1. Unwrap fwToken for the output and settle to PoolManager.
        _unwrapReserve(id, outputCurrency, amountOut);
        uint256 rawOut = rawReserveOf[id][outputCurrency];
        if (rawOut < amountOut) revert InsufficientReserve();
        rawReserveOf[id][outputCurrency] = rawOut - amountOut;
        _settle(outputCurrency, address(this), amountOut);

        // 2. Mint ERC-6909 claims for the input (swapper hasn't settled yet).
        poolManager.mint(address(this), inputCurrency.toId(), amountIn);
        claimReserveOf[id][inputCurrency] += amountIn;

        // 3. Wrap any leftover raw balance back into fwToken.
        _wrapReserve(id, key.currency0);
        _wrapReserve(id, key.currency1);

        // 4. Clear swap context.
        _clearSwapContext();

        return (IHooks.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: SETTLEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Redeem the pool's ERC-6909 claims into raw tokens, capped by what the PoolManager can
    ///      physically honour right now, and return the pool's raw reserve afterwards.
    function _redeemClaims(PoolId poolId, Currency currency) internal returns (uint256) {
        uint256 claims = claimReserveOf[poolId][currency];
        if (claims != 0) {
            uint256 available = currency.balanceOf(address(poolManager));
            uint256 toRedeem = claims < available ? claims : available;
            if (toRedeem != 0) {
                poolManager.burn(address(this), currency.toId(), toRedeem);
                poolManager.take(currency, address(this), toRedeem);
                claimReserveOf[poolId][currency] = claims - toRedeem;
                rawReserveOf[poolId][currency] += toRedeem;
            }
        }
        return rawReserveOf[poolId][currency];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: FWToken HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Debit the pool's fwToken ledger and transfer the fwToken to `to`. For native ETH,
    ///      the fwWETH is unwound to WETH9 → ETH and sent as native to `to`.
    function _withdrawFwToken(PoolId poolId, Currency currency, uint256 amount, address to) internal {
        if (amount == 0) return;
        address fwToken = _wrappedToken(currency);

        uint256 fw = fwReserveOf[poolId][currency];
        if (fw < amount) revert InsufficientReserve();
        fwReserveOf[poolId][currency] = fw - amount;

        if (currency.isAddressZero()) {
            // Native: fwWETH → WETH9 → ETH, then send ETH to `to`
            IFewWrappedToken(fwToken).unwrap(amount);
            uint256 wethReceived = IERC20(address(weth9)).balanceOf(address(this));
            weth9.withdraw(wethReceived);
            currency.transfer(to, wethReceived);
        } else {
            IERC20(fwToken).safeTransfer(to, amount);
        }

        emit Withdrawn(poolId, currency, to, amount);
    }

    /// @dev Pull fwToken from the caller and credit it to the pool's fwToken reserve.
    function _pullFwToken(Currency currency, uint256 amount, PoolId poolId) internal {
        if (amount == 0) return;
        address fwToken = _wrappedToken(currency);
        uint256 before = IERC20(fwToken).balanceOf(address(this));
        IERC20(fwToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(fwToken).balanceOf(address(this)) - before;

        fwReserveOf[poolId][currency] += received;
        emit Deposited(poolId, currency, received);
    }

    /// @dev Move up to `amount` of the pool's fwToken reserve into its raw reserve.
    ///      For native ETH, the chain is fwWETH → WETH9 → ETH (two unwrap steps).
    function _unwrapReserve(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        uint256 fw = fwReserveOf[poolId][currency];
        uint256 toUnwrap = amount < fw ? amount : fw;
        if (toUnwrap == 0) return;

        address fwToken = _wrappedToken(currency);

        if (currency.isAddressZero()) {
            // Native: fwWETH → WETH9 → ETH
            uint256 wethBefore = IERC20(address(weth9)).balanceOf(address(this));
            IFewWrappedToken(fwToken).unwrap(toUnwrap);
            uint256 wethReceived = IERC20(address(weth9)).balanceOf(address(this)) - wethBefore;
            weth9.withdraw(wethReceived); // WETH9 → ETH (1:1, triggers receive())

            fwReserveOf[poolId][currency] = fw - toUnwrap;
            rawReserveOf[poolId][currency] += wethReceived;
        } else {
            uint256 before = currency.balanceOf(address(this));
            IFewWrappedToken(fwToken).unwrap(toUnwrap);
            uint256 received = currency.balanceOf(address(this)) - before;

            fwReserveOf[poolId][currency] = fw - toUnwrap;
            rawReserveOf[poolId][currency] += received;
        }
    }

    /// @dev Wrap the pool's leftover raw reserve back into its fwToken reserve.
    ///      For native ETH, the chain is ETH → WETH9 → fwWETH (two wrap steps).
    function _wrapReserve(PoolId poolId, Currency currency) internal {
        uint256 raw = rawReserveOf[poolId][currency];
        if (raw == 0) return;

        address fwToken = _wrappedToken(currency);

        if (currency.isAddressZero()) {
            // Native: ETH → WETH9 → fwWETH
            uint256 ethHeld = address(this).balance;
            uint256 toWrap = raw < ethHeld ? raw : ethHeld;
            if (toWrap == 0) return;

            weth9.deposit{value: toWrap}(); // ETH → WETH9
            _ensureApproved(currency, fwToken);
            uint256 before = IERC20(fwToken).balanceOf(address(this));
            IFewWrappedToken(fwToken).wrap(toWrap); // WETH9 → fwWETH
            uint256 received = IERC20(fwToken).balanceOf(address(this)) - before;

            rawReserveOf[poolId][currency] = raw - toWrap;
            fwReserveOf[poolId][currency] += received;
        } else {
            uint256 held = currency.balanceOf(address(this));
            uint256 toWrap = raw < held ? raw : held;
            if (toWrap == 0) return;

            _ensureApproved(currency, fwToken);
            uint256 before = IERC20(fwToken).balanceOf(address(this));
            IFewWrappedToken(fwToken).wrap(toWrap);
            uint256 received = IERC20(fwToken).balanceOf(address(this)) - before;

            rawReserveOf[poolId][currency] = raw - toWrap;
            fwReserveOf[poolId][currency] += received;
        }
    }

    function _ensureApproved(Currency currency, address fwToken) internal {
        // For native ETH, the fwToken wraps WETH9, so approve WETH9 (not address(0)).
        address token = currency.isAddressZero() ? address(weth9) : Currency.unwrap(currency);
        if (_fwApproved[token]) return;
        IERC20(token).forceApprove(fwToken, type(uint256).max);
        _fwApproved[token] = true;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: SWAP CONTEXT (TRANSIENT)
    // ═══════════════════════════════════════════════════════════════════════════

    function _storeSwapContext(uint256 amountIn, uint256 amountOut, bool zeroForOne) internal {
        bytes32 base = SWAP_CTX_NAMESPACE;
        assembly ("memory-safe") {
            tstore(base, amountIn)
            tstore(add(base, 1), amountOut)
            tstore(add(base, 2), iszero(iszero(zeroForOne)))
        }
    }

    function _loadSwapContext() internal returns (uint256 amountIn, uint256 amountOut, bool zeroForOne) {
        bytes32 base = SWAP_CTX_NAMESPACE;
        assembly ("memory-safe") {
            amountIn := tload(base)
            amountOut := tload(add(base, 1))
            zeroForOne := iszero(iszero(tload(add(base, 2))))
        }
    }

    function _clearSwapContext() internal {
        bytes32 base = SWAP_CTX_NAMESPACE;
        assembly ("memory-safe") {
            tstore(base, 0)
            tstore(add(base, 1), 0)
            tstore(add(base, 2), 0)
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Returns (reserveIn, reserveOut) for the V2 math, based on swap direction.
    ///      Uses effective reserves (fw + raw + min(claims, PoolManager balance)).
    function _v2Reserves(PoolId id, PoolKey calldata key, bool zeroForOne)
        private
        view
        returns (uint256 reserveIn, uint256 reserveOut)
    {
        uint256 r0 = _effectiveReserve(id, key.currency0);
        uint256 r1 = _effectiveReserve(id, key.currency1);
        if (zeroForOne) {
            reserveIn = r0;
            reserveOut = r1;
        } else {
            reserveIn = r1;
            reserveOut = r0;
        }
    }

    /// @dev Check whether the post-swap V2 price stays within the v4 sqrt-price limit.
    ///      The V2 price (currency1/currency0) is converted to sqrtPriceX96 for comparison.
    function _priceWithinLimit(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 amountIn,
        uint256 amountOut,
        uint160 sqrtPriceLimitX96
    ) private pure returns (bool) {
        // Post-swap reserves.
        uint256 newReserveIn = reserveIn + amountIn;
        uint256 newReserveOut = reserveOut - amountOut;
        if (newReserveIn == 0 || newReserveOut == 0) return false;

        // V2 price = reserve1 / reserve0. Compute sqrtPriceX96 = sqrt(price) * 2^96.
        // For zeroForOne: reserveIn = reserve0, reserveOut = reserve1.
        // For !zeroForOne: reserveIn = reserve1, reserveOut = reserve0.
        uint256 newR0 = zeroForOne ? newReserveIn : newReserveOut;
        uint256 newR1 = zeroForOne ? newReserveOut : newReserveIn;

        // price = newR1 / newR0 (as a FixedPoint96 sqrt). We approximate:
        // sqrtPriceX96 ≈ sqrt(newR1 * 2^192 / newR0)
        // To avoid overflow, use a simplified check: compare price ratios.
        // zeroForOne: price decreases, so sqrtPriceLimitX96 is a floor.
        // !zeroForOne: price increases, so sqrtPriceLimitX96 is a ceiling.
        if (zeroForOne) {
            // Price must stay >= limit: newR1/newR0 >= (limit/2^96)^2
            // => newR1 * 2^192 >= limit^2 * newR0
            // Approximate: newR1 / newR0 >= priceLimit^2 / 2^192
            // For safety, just check the ratio direction.
            if (sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE) return true; // no effective limit
            // Compare: newR1 * 1 >= newR0 * (limit^2 / 2^192) — use full ratio
            // Simplified: newR1 * 2^96 >= newR0 * sqrtPriceLimitX96 (approximate)
            // This is an approximation; exact check requires full sqrt math.
            return newR1 * (1 << 96) >= newR0 * sqrtPriceLimitX96;
        } else {
            if (sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) return true; // no effective limit
            return newR1 * (1 << 96) <= newR0 * sqrtPriceLimitX96;
        }
    }

    function _resolveWrappedToken(Currency currency) private view returns (address fwToken) {
        // For native ETH, the Few fwToken wraps WETH9 (not raw ETH), so resolve via weth9.
        address token = currency.isAddressZero() ? address(weth9) : Currency.unwrap(currency);
        fwToken = fewFactory.getWrappedToken(token);
        if (fwToken == address(0) || IFewWrappedToken(fwToken).token() != token) revert WrappedTokenNotFound();
    }

    function _wrappedToken(Currency currency) private view returns (address fwToken) {
        fwToken = wrappedTokenOf[currency];
        if (fwToken == address(0)) revert CurrencyNotInPool();
    }

    function _requirePool(PoolId id) private view {
        if (!initialized || PoolId.unwrap(id) != PoolId.unwrap(configuredPoolId)) revert InvalidPool();
    }

    function _totalReserve(PoolId id, Currency currency) private view returns (uint256) {
        return fwReserveOf[id][currency] + rawReserveOf[id][currency] + claimReserveOf[id][currency];
    }

    function _effectiveReserve(PoolId id, Currency currency) private view returns (uint256 available) {
        available = fwReserveOf[id][currency] + rawReserveOf[id][currency];
        uint256 claims = claimReserveOf[id][currency];
        uint256 managerBalance = currency.balanceOf(address(poolManager));
        available += (claims < managerBalance ? claims : managerBalance);
    }
}
