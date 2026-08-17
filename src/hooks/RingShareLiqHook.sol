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
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {OwnedALFHook} from "alf/base/OwnedALFHook.sol";
import {FeeLib} from "alf/libraries/FeeLib.sol";
import {
    Distribution,
    LiquidityBucket,
    MAX_BUCKETS,
    computeAllocations,
    activeLiquidity
} from "alf/types/Distribution.sol";
import {ActiveLiquidity, activeLiquidityFor} from "alf/types/ActiveLiquidity.sol";
import {JITLock, jitLockFor, requireJITNotInProgress} from "alf/types/JITLock.sol";

import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";
import {IFewFactory} from "../interfaces/external/IFewFactory.sol";

/// @title Ring Share Liquidity Hook — single-pool JIT liquidity injection
/// @notice The hook holds a token reserve as Few wrapped tokens (fwTokens) and lends it to a single
///         pool for the duration of each swap: `beforeSwap` unwraps what is needed and injects it as
///         concentrated liquidity across owner-configured tick ranges, the pool swaps against that
///         liquidity as it would against any LP, and `afterSwap` withdraws the positions and wraps
///         the proceeds back. The pool itself needs only enough real liquidity to exist, while depth
///         comes from the reserve.
///
///         **One hook per pool.** Each hook instance is deployed via `AllowlistedFactory` and serves
///         exactly one pool, set up through `initializePool` + `bootstrap`. This eliminates the
///         cross-pool delta-attribution and shared-balance hazards of a multi-pool design: the
///         hook's `currencyDelta` is always this pool's delta, and the reserve ledgers track only
///         this pool's capital.
///
///         **Admin-owned capital.** Reserves are funded by the owner via `deposit` / `bootstrap` and
///         withdrawn via `withdraw`. There is no share accounting and no external LP entry point;
///         the owner is the sole capital provider. This mirrors `DualPoolHook`'s structure but
///         replaces ERC-4626 vault rehypothecation with fwToken wrapping through the Few protocol.
///
///         Injecting liquidity — rather than answering the swap with a `BeforeSwapDelta` — is what
///         makes the hook work behind the UniversalRouter, whose SWAP → SETTLE → TAKE order means
///         the PoolManager does not yet hold the swapper's input when `beforeSwap` runs.
///
/// ## Design
///
///   - **Single-pool reserve ledgers.** `fwReserveOf / rawReserveOf / claimReserveOf` are keyed by
///     `PoolId` for consistency with the ALF type signatures, but only one pool is ever initialized.
///     The ledgers, not `balanceOf`, are the source of truth for sizing, settlement and withdrawal;
///     the physical balance is only ever used as a defensive cap.
///
///   - **Per-pool configuration.** `initializePool` creates the pool with its distribution and
///     initial price; `bootstrap` seeds the reserve and flips liveness on; `setDistribution` updates
///     tradable ranges; `setPoolLive` pauses/resumes.
///
///   - **One open JIT cycle at a time.** The `JITLock` transient lock rejects reentrant cycles.
///     Since the hook serves a single pool, cross-pool nesting is structurally impossible.
///
///   - **Claims, never opportunistic `take`.** A positive delta always becomes ERC-6909 claims,
///     redeemed at the start of the next cycle or via `sweepClaims`.
///
///   - **Price-manipulation guard.** The pool's current tick must fall inside one of the configured
///     buckets or the hook does not intervene at all.
///
///   - **Owner model.** OZ `Ownable2Step` (via `OwnedALFHook`), per-pool `setPoolLive`, and
///     owner-gated pool initialization, deposits and withdrawals. Every configuration and
///     fund-movement entry point is rejected while a JIT cycle is in flight.
///
/// ## JIT lifecycle
///
///   beforeSwap:
///     1. Gate: pool live, distribution configured, current tick inside a bucket
///     2. Enter the JIT lock
///     3. Redeem ERC-6909 claims, size the deployment against the reserve, unwrap only the shortfall
///     4. `modifyLiquidity` each bucket, then settle the resulting debt from the raw reserve
///     5. Return ZERO_DELTA — the AMM swaps against the injected liquidity as usual
///
///   afterSwap:
///     1. Remove every bucket position recorded in transient storage
///     2. Resolve the net delta: debt → settle from the raw reserve; credit → mint claims
///     3. Wrap the leftover raw balance back into fwToken reserve
///     4. Clear the JIT lock
///
/// @dev Native currency (`address(0)`) is not supported: reserves are held as fwTokens and the hook
///      has no `receive()`. `beforeInitialize` rejects such pools (inherited from `OwnedALFHook`).
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

    /// @notice Salt for the hook's LP positions in the PoolManager, distinguishing them
    ///         from positions created by other hooks or LPs on the same pool.
    bytes32 private constant LP_SALT = bytes32(uint256(0x52495A47)); // "RIZG"

    // ═══════════════════════════════════════════════════════════════════════════
    //                              TYPES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Configuration for initializing a new pool. Passed to `initializePool`.
    /// @param sqrtPriceX96  Initial sqrt price (Q64.96) for the v4 pool.
    /// @param distribution  Liquidity distribution buckets (weights must sum to 10_000).
    struct PoolConfig {
        uint160 sqrtPriceX96;
        LiquidityBucket[] distribution;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              STATE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Per-pool liquidity distribution (tick ranges and weights). Set at initialization via
    ///      `initializePool`, updatable via `setDistribution`, read by the JIT cycle.
    Distribution internal _distribution;

    /// @notice The Few factory used to resolve fwToken addresses for each underlying currency.
    IFewFactory public immutable fewFactory;

    /// @notice The contract that deployed this hook. Canonical deployments go through the
    ///         `AllowlistedFactory`, so aggregators and routers can verify provenance via
    ///         `factory()` against the known factory address.
    address public immutable factory;

    /// @notice Pool-owned fwToken reserve, keyed by the pool's *underlying* currency.
    mapping(PoolId => mapping(Currency => uint256)) public fwReserveOf;

    /// @notice Pool-owned raw token reserve. Non-zero only mid-cycle and for wrap dust.
    mapping(PoolId => mapping(Currency => uint256)) public rawReserveOf;

    /// @notice Pool-owned ERC-6909 claims held in the PoolManager, minted for a positive delta
    ///         that the PoolManager could not yet pay in real tokens. Redeemed at the start of the
    ///         next JIT cycle, or by `sweepClaims`.
    mapping(PoolId => mapping(Currency => uint256)) public claimReserveOf;

    /// @dev Underlying tokens already granted an allowance to their fwToken.
    mapping(address => bool) internal _fwApproved;

    // ═══════════════════════════════════════════════════════════════════════════
    //                              EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new pool is initialized via `initializePool`.
    event PoolCreated(PoolId indexed poolId);

    /// @notice Emitted when the liquidity distribution is replaced via `setDistribution`.
    event DistributionUpdated(PoolId indexed poolId);

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
    error WrappedTokenNotFound();
    error InsufficientReserve();
    error TransferFailed();
    error UnauthorizedCallback();
    error LiquidityNotAllowed();
    error InvalidHookAddress();
    error DynamicFeeNotSupported();
    error PoolAlreadyBootstrapped();
    error BootstrapIncomplete();

    // ═══════════════════════════════════════════════════════════════════════════
    //                              CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════════

    /// @param _pm         The Uniswap v4 PoolManager.
    /// @param maxGas_     Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_      Initial contract owner. Transferable via OZ `Ownable2Step`.
    /// @param _fewFactory The Few factory for resolving fwToken addresses.
    constructor(IPoolManager _pm, uint32 maxGas_, address owner_, IFewFactory _fewFactory)
        OwnedALFHook(_pm, maxGas_, owner_)
    {
        if (address(_fewFactory) == address(0)) revert WrappedTokenNotFound();
        fewFactory = _fewFactory;
        factory = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Reverts {JITInProgress} if the pool has a JIT cycle in flight.
    modifier whenJITNotInProgress() {
        requireJITNotInProgress();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: POOL INITIALIZATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Initialize a new pool with a liquidity distribution.
    /// @dev    Calls `poolManager.initialize` internally. The pool's LP fee is taken from
    ///         `key.fee` and is static. Native ETH (`address(0)`) is rejected; wrap as WETH.
    ///         The pool is created not live: swaps revert with `PoolNotLive` until the owner
    ///         calls `bootstrap`, which seeds the reserve and flips liveness on.
    /// @param key    The PoolKey (must reference this hook). `key.fee` is the static LP fee;
    ///               dynamic-fee pools are rejected.
    /// @param config Pool configuration including distribution and initial sqrt price.
    /// @return tick  The initial tick assigned by the PoolManager.
    function initializePool(PoolKey calldata key, PoolConfig calldata config)
        external
        onlyOwner
        returns (int24 tick)
    {
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert NativeNotSupported();
        if (key.fee.isDynamicFee()) revert DynamicFeeNotSupported();

        // Verify fwTokens exist for both currencies before creating the pool.
        if (fewFactory.getWrappedToken(Currency.unwrap(key.currency0)) == address(0)) revert WrappedTokenNotFound();
        if (fewFactory.getWrappedToken(Currency.unwrap(key.currency1)) == address(0)) revert WrappedTokenNotFound();

        PoolId poolId = key.toId();
        _distribution.set(poolId, config.distribution, key.tickSpacing);

        tick = poolManager.initialize(key, config.sqrtPriceX96);
        // Pool starts not live: liveness is gated on `bootstrap`.
        emit PoolCreated(poolId);
    }

    /// @notice Seed the pool's reserve with fwTokens and flip it to live.
    /// @dev    Only the owner may bootstrap. Pulls fwToken0 and fwToken1 from the caller and
    ///         credits them to the pool's reserve. Flips liveness to true, enabling swaps.
    ///         Reverts if the pool is already bootstrapped (liveness already true).
    /// @param key     The pool to bootstrap.
    /// @param amount0 fwToken0 amount to deposit for currency0.
    /// @param amount1 fwToken1 amount to deposit for currency1.
    function bootstrap(PoolKey calldata key, uint256 amount0, uint256 amount1)
        external
        onlyOwner
        nonReentrant
        whenJITNotInProgress
    {
        PoolId poolId = key.toId();
        if (_liveness.isLive(poolId)) revert PoolAlreadyBootstrapped();

        if (amount0 > 0) _pullFwToken(key.currency0, amount0, poolId);
        if (amount1 > 0) _pullFwToken(key.currency1, amount1, poolId);

        // First successful bootstrap flips the pool to live.
        _liveness.setLive(poolId, true);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: RESERVES
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Fund the pool's reserve with the fwToken of `currency`.
    /// @param key      The pool the capital is credited to.
    /// @param currency The pool currency (the *underlying* token, not the fwToken).
    /// @param amount   fwToken amount to pull from the caller.
    function deposit(PoolKey calldata key, Currency currency, uint256 amount)
        external
        onlyOwner
        nonReentrant
        whenJITNotInProgress
    {
        _pullFwToken(currency, amount, key.toId());
    }

    /// @notice Withdraw a pool's fwToken reserve.
    /// @dev Debits the pool's ledger first, so the reserve can never be overdrawn.
    function withdraw(PoolKey calldata key, Currency currency, uint256 amount, address to)
        external
        onlyOwner
        nonReentrant
        whenJITNotInProgress
    {
        if (to == address(0)) revert NativeNotSupported();

        PoolId poolId = key.toId();
        uint256 fw = fwReserveOf[poolId][currency];
        if (fw < amount) revert InsufficientReserve();
        fwReserveOf[poolId][currency] = fw - amount;

        address fwToken = fewFactory.getWrappedToken(Currency.unwrap(currency));
        if (fwToken == address(0)) revert WrappedTokenNotFound();
        if (!IERC20(fwToken).transfer(to, amount)) revert TransferFailed();

        emit Withdrawn(poolId, currency, to, amount);
    }

    /// @notice Convert the pool's outstanding ERC-6909 claims back into its fwToken reserve.
    /// @dev Claims are only redeemable inside a PoolManager unlock, so this opens one.
    function sweepClaims(PoolKey calldata key) external onlyOwner nonReentrant whenJITNotInProgress {
        poolManager.unlock(abi.encode(key));
        emit ClaimsSwept(key.toId());
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only callable by the PoolManager as a re-entrant continuation of our own
    ///      `poolManager.unlock` call inside `sweepClaims`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();
        PoolKey memory key = abi.decode(data, (PoolKey));
        PoolId poolId = key.toId();

        _redeemClaims(poolId, key.currency0);
        _redeemClaims(poolId, key.currency1);
        _wrapReserve(poolId, key.currency0);
        _wrapReserve(poolId, key.currency1);

        return "";
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: OWNER CONFIGURATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Replace the liquidity distribution for the pool.
    /// @dev    Weights must sum to 10_000. Ticks must be aligned to tickSpacing.
    ///         Reverts during an active JIT cycle to prevent orphaning live LP positions.
    function setDistribution(PoolKey calldata key, LiquidityBucket[] calldata buckets)
        external
        onlyOwner
        whenJITNotInProgress
    {
        _distribution.set(key.toId(), buckets, key.tickSpacing);
        emit DistributionUpdated(key.toId());
    }

    /// @notice Enable or disable pool liveness for emergency pause/resume.
    /// @dev    When toggled to false, `_beforeSwap` reverts with `PoolNotLive`, pausing the pool.
    function setPoolLive(PoolKey calldata key, bool live) external onlyOwner whenJITNotInProgress {
        _liveness.setLive(key.toId(), live);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        EXTERNAL: VIEWS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The current liquidity distribution for the pool.
    function getDistribution(PoolId poolId) external view returns (LiquidityBucket[] memory) {
        return _distribution.get(poolId);
    }

    /// @notice Total reserves managed by this hook for the pool (fwToken + raw + claims).
    function getReserves(PoolKey calldata key) external view override returns (uint256 token0, uint256 token1) {
        PoolId poolId = key.toId();
        token0 = fwReserveOf[poolId][key.currency0] + rawReserveOf[poolId][key.currency0]
            + claimReserveOf[poolId][key.currency0];
        token1 = fwReserveOf[poolId][key.currency1] + rawReserveOf[poolId][key.currency1]
            + claimReserveOf[poolId][key.currency1];
    }

    /// @notice Assets available for immediate swapping. For fwToken reserves this equals
    ///         `getReserves` since fwTokens can be unwrapped at will (no vault utilization cap).
    function getEffectiveLiquidity(PoolKey calldata key)
        external
        view
        override
        returns (uint256 token0, uint256 token1)
    {
        return this.getReserves(key);
    }

    /// @notice Indicative quote against hypothetical JIT liquidity.
    /// @dev Uses current active distribution-bucket liquidity for a compact view quote.
    ///      The result is an upper bound fit for ranking, not a precise execution prediction.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (uint256 amountIn, uint256 amountOut) = _simulateIndicative(key, zeroForOne, amountSpecified, limit);
        if (amountSpecified < 0) {
            outputAmount = amountOut;
        } else {
            outputAmount = amountOut >= uint256(amountSpecified) ? amountIn : 0;
        }
    }

    /// @notice Simulate a price-bounded swap against hypothetical JIT liquidity.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata
    ) external view override returns (uint256 amountIn, uint256 amountOut) {
        return _simulateIndicative(key, zeroForOne, amountSpecified, sqrtPriceLimitX96);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        PUBLIC: HOOK PERMISSIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Required v4 hook flags:
    ///      - beforeInitialize: block direct init (force initializePool)
    ///      - beforeAddLiquidity / beforeRemoveLiquidity: restrict to hook-only LP
    ///      - beforeSwap: JIT deployment
    ///      - afterSwap: JIT teardown + delta resolution
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
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: HOOK CALLBACKS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev External LP additions are blocked. v4-core's `Hooks.noSelfCall` skips the hook
    ///      callback entirely when the hook itself is the caller, so the only path that
    ///      reaches this body is an external `modifyLiquidity` call, which is always rejected.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev External LP removals are blocked. Same `noSelfCall` reasoning as `_beforeAddLiquidity`.
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    /// @dev JIT entry point. Deploys multi-range JIT liquidity under the JIT lock.
    ///      Reverts when the pool is paused (`!live`). Routers see an explicit failure.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        _liveness.requireLive(poolId);

        LiquidityBucket[] memory buckets = _distribution.get(poolId);
        if (buckets.length == 0) return _noJIT();

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);

        // Price-manipulation guard: only serve the tradable ranges the owner configured.
        if (!_tickCovered(buckets, tick)) return _noJIT();

        jitLockFor(poolId).enter();
        _deployJIT(poolId, key, buckets, sqrtPriceX96);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev JIT teardown. Removes all bucket positions, resolves the hook's net delta for both
    ///      currencies, wraps leftover raw balance back into fwToken reserve, and clears the lock.
    ///      If `_beforeSwap` declined to intervene (no lock set), there is nothing to unwind.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        if (!_isJITLocked(poolId)) return (IHooks.afterSwap.selector, 0);

        _removeJIT(poolId, key);
        _resolveCurrency(poolId, key.currency0);
        _resolveCurrency(poolId, key.currency1);
        _wrapReserve(poolId, key.currency0);
        _wrapReserve(poolId, key.currency1);

        jitLockFor(poolId).clear();
        return (IHooks.afterSwap.selector, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: JIT LIFECYCLE
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Deploy JIT liquidity across all distribution buckets.
    ///
    ///      1. Redeem claims — the cheapest capital.
    ///      2. Size the deployment against the pool's whole reserve.
    ///      3. Unwrap only the shortfall, so capital the deployment does not need stays wrapped.
    ///      4. Deploy each bucket, then settle the resulting debt from the raw reserve.
    function _deployJIT(PoolId poolId, PoolKey calldata key, LiquidityBucket[] memory buckets, uint160 sqrtPriceX96)
        internal
    {
        uint256 raw0 = _redeemClaims(poolId, key.currency0);
        uint256 raw1 = _redeemClaims(poolId, key.currency1);

        uint256 bal0 = raw0 + fwReserveOf[poolId][key.currency0];
        uint256 bal1 = raw1 + fwReserveOf[poolId][key.currency1];
        if (bal0 == 0 && bal1 == 0) return;

        (uint128[MAX_BUCKETS] memory liqs, uint256 need0, uint256 need1) =
            computeAllocations(buckets, sqrtPriceX96, bal0, bal1);
        if (need0 == 0 && need1 == 0) return;

        if (need0 > raw0) _unwrapReserve(poolId, key.currency0, need0 - raw0);
        if (need1 > raw1) _unwrapReserve(poolId, key.currency1, need1 - raw1);

        ActiveLiquidity slots = activeLiquidityFor(poolId);
        uint256 n = buckets.length;
        for (uint256 i; i < n; ++i) {
            uint128 liq = liqs[i];
            if (liq == 0) continue;
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: buckets[i].tickLower,
                    tickUpper: buckets[i].tickUpper,
                    liquidityDelta: int256(uint256(liq)),
                    salt: LP_SALT
                }),
                ""
            );
            slots.store(i, liq);
        }

        // Settle the debt from deploying liquidity so the hook's delta is zero before the swap.
        _settleDebt(poolId, key.currency0);
        _settleDebt(poolId, key.currency1);
    }

    /// @dev Remove every position this cycle deployed, reading the transient record.
    function _removeJIT(PoolId poolId, PoolKey calldata key) internal {
        LiquidityBucket[] memory buckets = _distribution.get(poolId);
        ActiveLiquidity slots = activeLiquidityFor(poolId);
        uint256 n = buckets.length;

        for (uint256 i; i < n; ++i) {
            uint128 liq = slots.takeAndClear(i);
            if (liq == 0) continue;
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: buckets[i].tickLower,
                    tickUpper: buckets[i].tickUpper,
                    liquidityDelta: -int256(uint256(liq)),
                    salt: LP_SALT
                }),
                ""
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: SETTLEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Resolve the hook's net delta for one currency, crediting or debiting the pool's ledger.
    ///      A positive delta always becomes ERC-6909 claims (the swapper hasn't settled yet).
    function _resolveCurrency(PoolId poolId, Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta > 0) {
            uint256 credit = uint256(delta);
            poolManager.mint(address(this), currency.toId(), credit);
            claimReserveOf[poolId][currency] += credit;
        } else if (delta < 0) {
            _settleDebt(poolId, currency);
        }
    }

    /// @dev Pay off the hook's whole debt for `currency` out of the pool's reserve. Falls back to
    ///      unwrapping if the raw ledger is a few wei short of the rounded-up deployment cost.
    function _settleDebt(PoolId poolId, Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta >= 0) return;
        uint256 owed = SignedMath.abs(delta);

        uint256 raw = rawReserveOf[poolId][currency];
        if (raw < owed) {
            _unwrapReserve(poolId, currency, owed - raw);
            raw = rawReserveOf[poolId][currency];
            if (raw < owed) revert InsufficientReserve();
        }
        rawReserveOf[poolId][currency] = raw - owed;
        _settle(currency, address(this), owed);
    }

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

    /// @dev Pull fwToken from the caller and credit it to the pool's fwToken reserve.
    function _pullFwToken(Currency currency, uint256 amount, PoolId poolId) internal {
        if (amount == 0) return;
        address fwToken = fewFactory.getWrappedToken(Currency.unwrap(currency));
        if (fwToken == address(0)) revert WrappedTokenNotFound();

        uint256 before = IERC20(fwToken).balanceOf(address(this));
        IERC20(fwToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(fwToken).balanceOf(address(this)) - before;

        fwReserveOf[poolId][currency] += received;
        emit Deposited(poolId, currency, received);
    }

    /// @dev Move up to `amount` of the pool's fwToken reserve into its raw reserve.
    function _unwrapReserve(PoolId poolId, Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        uint256 fw = fwReserveOf[poolId][currency];
        uint256 toUnwrap = amount < fw ? amount : fw;
        if (toUnwrap == 0) return;

        address fwToken = fewFactory.getWrappedToken(Currency.unwrap(currency));
        if (fwToken == address(0)) revert WrappedTokenNotFound();

        uint256 before = currency.balanceOf(address(this));
        IFewWrappedToken(fwToken).unwrap(toUnwrap);
        uint256 received = currency.balanceOf(address(this)) - before;

        fwReserveOf[poolId][currency] = fw - toUnwrap;
        rawReserveOf[poolId][currency] += received;
    }

    /// @dev Wrap the pool's leftover raw reserve back into its fwToken reserve.
    function _wrapReserve(PoolId poolId, Currency currency) internal {
        uint256 raw = rawReserveOf[poolId][currency];
        if (raw == 0) return;

        address fwToken = fewFactory.getWrappedToken(Currency.unwrap(currency));
        if (fwToken == address(0)) return;

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

    function _ensureApproved(Currency currency, address fwToken) internal {
        address token = Currency.unwrap(currency);
        if (_fwApproved[token]) return;
        IERC20(token).forceApprove(fwToken, type(uint256).max);
        _fwApproved[token] = true;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: PRICING
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Simulate a swap against hypothetical JIT liquidity for indicative quoting.
    function _simulateIndicative(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) internal view returns (uint256 amountIn, uint256 amountOut) {
        PoolId poolId = key.toId();

        if (!_liveness.isLive(poolId)) return (0, 0);
        uint24 feePips = key.fee;

        (uint256 bal0, uint256 bal1) = this.getReserves(key);
        if (bal0 == 0 && bal1 == 0) return (0, 0);

        uint160 sqrtPriceX96;
        int24 currentTick;
        {
            uint24 protocolFee;
            (sqrtPriceX96, currentTick, protocolFee,) = poolManager.getSlot0(poolId);
            if (sqrtPriceX96 == 0) return (0, 0);
            feePips = FeeLib.effectiveSwapFee(feePips, protocolFee, zeroForOne);
        }

        uint128 liquidity = activeLiquidity(_distribution.get(poolId), sqrtPriceX96, currentTick, bal0, bal1);
        if (liquidity == 0 || amountSpecified == 0) return (0, 0);

        (, uint256 stepIn, uint256 stepOut, uint256 feeAmount) =
            SwapMath.computeSwapStep(sqrtPriceX96, sqrtPriceLimitX96, liquidity, amountSpecified, feePips);
        amountIn = stepIn + feeAmount;
        amountOut = stepOut;

        // Cap output at the deliverable reserve so the quote stays an honest upper bound.
        uint256 outReserve = zeroForOne ? bal1 : bal0;
        if (amountOut > outReserve) {
            uint160 drainLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            (, uint256 drainIn,, uint256 drainFee) =
                SwapMath.computeSwapStep(sqrtPriceX96, drainLimit, liquidity, outReserve.toInt256(), feePips);
            amountIn = drainIn + drainFee;
            amountOut = outReserve;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                        INTERNAL: HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Whether the current tick sits inside one of the configured tradable ranges.
    function _tickCovered(LiquidityBucket[] memory buckets, int24 tick) internal pure returns (bool) {
        uint256 n = buckets.length;
        for (uint256 i; i < n; ++i) {
            if (tick >= buckets[i].tickLower && tick < buckets[i].tickUpper) return true;
        }
        return false;
    }

    function _noJIT() private pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Whether the JIT lock is set for `poolId`. Reads the per-pool transient slot that
    ///      `JITLock.enter` writes and `JITLock.clear` zeroes.
    function _isJITLocked(PoolId poolId) private view returns (bool locked) {
        bytes32 slot = JITLock.unwrap(jitLockFor(poolId));
        assembly ("memory-safe") {
            locked := iszero(iszero(tload(slot)))
        }
    }
}
