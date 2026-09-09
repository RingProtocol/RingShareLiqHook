// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BaseHook} from "../utils/BaseHook.sol";
import {DeltaResolver} from "../base/DeltaResolver.sol";
import {RingLPPlanner} from "../libraries/RingLPPlanner.sol";
import {FewV2Math} from "../libraries/FewV2Math.sol";
import {IFewFactory} from "../interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../interfaces/external/IFewWrappedToken.sol";
import {ISwapV2Factory, ISwapV2Pair} from "../interfaces/external/IFewV2.sol";
import {jitLockFor, requireJITNotInProgress} from "../alf/types/JITLock.sol";

/// @notice Single v4 pool with full-range base liquidity and real per-order JIT LP sourced from Ring FewV2.
/// @dev Both swap-return-delta permissions are OFF. PoolManager's ordinary liquidity debts
///      remain open until afterSwap removes the position. A prefunded router supplies the
///      input used on Ring. Owner capital is only a strictly bounded raw-token rounding buffer.
///      The stored v4 price is the starting point for the combined base-plus-JIT quote.
contract RingBackedLiqHook is BaseHook, DeltaResolver, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    uint256 public constant MAX_ROUNDING_LOSS = 8; // raw token units per currency per successful swap
    uint256 public constant MIN_BUFFER = 16;
    bytes32 private constant LP_SALT = keccak256("RingBackedLiqHook.position");
    IFewFactory public immutable fewFactory;
    ISwapV2Factory public immutable fewV2Factory;
    address public immutable factory;
    bool public initialized;
    bool public live;
    PoolId public configuredPoolId;
    PoolKey private _key;
    address[] private _path; // pinned canonical fwTokens, currency0 -> currency1
    address[] private _pairs;
    mapping(Currency => uint256) public roundingReserve;
    RingLPPlanner.Plan private _active;
    uint256 private _balance0Before;
    uint256 private _balance1Before;
    uint256 private _activeDonationLimit;

    error InvalidPool();
    error InvalidRoute();
    error PoolNotLive();
    error FullRangeLiquidityOnly();
    error ProtocolFeeNotSupported();
    error InsufficientRoundingBuffer();
    error UnexpectedTokenDelta();
    error UnexpectedFill();
    error PriceLimitExceeded();
    error UnexpectedLiquidity();
    error RoundingLossExceeded();
    error InvalidRecipient();
    error RenounceOwnershipDisabled();
    event PoolCreated(PoolId indexed poolId);
    event LiveSet(bool live);
    event RoundingFunded(Currency indexed currency, uint256 amount);
    event RingBackedSwap(
        PoolId indexed poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 loss0, uint256 loss1
    );

    constructor(IPoolManager manager, IFewFactory few, ISwapV2Factory dex, address owner_)
        BaseHook(manager)
        Ownable(owner_)
    {
        if (address(manager) == address(0) || address(few) == address(0) || address(dex) == address(0)) revert InvalidPool();
        fewFactory = few;
        fewV2Factory = dex;
        factory = msg.sender;
    }
    modifier idle() {
        requireJITNotInProgress();
        _;
    }

    /// @dev An owner is needed to replenish the rounding reserve and recover from pauses.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeAddLiquidity = true;
        p.beforeRemoveLiquidity = true;
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function initializePool(PoolKey calldata key, address[] calldata fwPath, uint160 initialSqrtPriceX96)
        external
        onlyOwner
        idle
        nonReentrant
    {
        if (
            initialized || address(key.hooks) != address(this) || key.fee != 0 || key.tickSpacing <= 0
                || key.tickSpacing > 200 || key.currency0.isAddressZero() || key.currency1.isAddressZero()
        ) revert InvalidPool();
        if (fwPath.length < 2 || fwPath.length > 4) revert InvalidRoute();
        for (uint256 i; i < fwPath.length; ++i) {
            address underlying = IFewWrappedToken(fwPath[i]).token();
            if (underlying == address(0) || fewFactory.getWrappedToken(underlying) != fwPath[i]) revert InvalidRoute();
            for (uint256 j; j < i; ++j) {
                if (fwPath[j] == fwPath[i]) revert InvalidRoute();
            }
            if (i == 0 && underlying != Currency.unwrap(key.currency0)) revert InvalidRoute();
            if (i == fwPath.length - 1 && underlying != Currency.unwrap(key.currency1)) revert InvalidRoute();
            _path.push(fwPath[i]);
            if (i > 0) {
                address pair = fewV2Factory.getPair(fwPath[i - 1], fwPath[i]);
                if (pair == address(0)) revert InvalidRoute();
                _reserves(pair, fwPath[i - 1], fwPath[i]);
                _pairs.push(pair);
            }
        }
        initialized = true;
        configuredPoolId = key.toId();
        _key = key;
        poolManager.initialize(key, initialSqrtPriceX96);
        emit PoolCreated(configuredPoolId);
    }

    function fundRounding(Currency currency, uint256 amount) external onlyOwner idle nonReentrant {
        _requireCurrency(currency);
        uint256 beforeBalance = currency.balanceOfSelf();
        IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        if (currency.balanceOfSelf() != beforeBalance + amount) revert UnexpectedTokenDelta();
        roundingReserve[currency] += amount;
        emit RoundingFunded(currency, amount);
    }

    function withdrawRounding(Currency currency, uint256 amount, address to) external onlyOwner idle nonReentrant {
        _requireCurrency(currency);
        if (to == address(0)) revert InvalidRecipient();
        roundingReserve[currency] -= amount;
        currency.transfer(to, amount);
    }

    function setPoolLive(bool enabled) external onlyOwner idle {
        if (!initialized) revert InvalidPool();
        if (enabled) {
            _requireBuffers();
            if (poolManager.getLiquidity(configuredPoolId) == 0) revert UnexpectedLiquidity();
        }
        live = enabled;
        emit LiveSet(enabled);
    }

    function getRoute() external view returns (address[] memory path, address[] memory pairs) {
        return (_path, _pairs);
    }

    /// @notice Nonbinding plan including the real LP amounts (within 2 raw units in the user's favour).
    /// @dev Reverts for unavailable routes, insufficient rounding buffer, or unrepresentable prices.
    function quote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified)
        external
        view
        idle
        returns (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p)
    {
        return _quote(key, zeroForOne, amountSpecified);
    }

    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        view
        returns (uint256)
    {
        try this.quote(key, zeroForOne, amountSpecified) returns (uint256, uint256, RingLPPlanner.Plan memory p) {
            return amountSpecified < 0 ? p.amountOut : p.amountIn;
        } catch {
            return 0;
        }
    }

    function _quote(PoolKey calldata key, bool forward, int256 specified)
        private
        view
        returns (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p)
    {
        _requirePool(key);
        if (!live) revert PoolNotLive();
        _requireBuffers();
        if (specified == 0 || specified == type(int256).min) revert UnexpectedFill();
        uint256 requested = SafeCast.toUint256(specified < 0 ? -specified : specified);
        if (requested > type(uint96).max) revert UnexpectedFill();
        (,, uint24 protocolFee,) = poolManager.getSlot0(configuredPoolId);
        if (protocolFee != 0) revert ProtocolFeeNotSupported();
        (address[] memory tokens, address[] memory pairs) = _route(forward);
        uint128 baseLiquidity = poolManager.getLiquidity(configuredPoolId);
        if (baseLiquidity == 0) revert UnexpectedLiquidity();
        (uint160 start,,,) = poolManager.getSlot0(configuredPoolId);
        (ringIn, ringOut, p) = _findHybridPlan(start, baseLiquidity, specified, forward, key.tickSpacing, tokens, pairs);
    }

    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert InvalidPool(); // initialization must pass through the owner-gated entry point
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        _requireFullRange(key, params);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        _requireFullRange(key, params);
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requirePool(key);
        jitLockFor(configuredPoolId).enter();
        (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p) =
            _quote(key, params.zeroForOne, params.amountSpecified);
        if (params.zeroForOne ? params.sqrtPriceLimitX96 >= p.end : params.sqrtPriceLimitX96 <= p.end) {
            revert PriceLimitExceeded();
        }
        _balance0Before = key.currency0.balanceOfSelf();
        _balance1Before = key.currency1.balanceOfSelf();
        _active = p;
        if (p.liquidity == 0) {
            _activeDonationLimit = MAX_ROUNDING_LOSS;
        } else {
            (address[] memory tokens, address[] memory pairs) = _route(params.zeroForOne);
            _activeDonationLimit = _inputQuantum(tokens, pairs, ringOut);
        }
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        if (p.liquidity != 0) {
            _take(input, address(this), ringIn);
            _execute(params.zeroForOne, SafeCast.toInt256(ringOut), ringIn, ringOut);
            _settle(output, address(this), ringOut);
        }
        // Intentionally do NOT settle liquidity-add debts here. The position is removed in
        // afterSwap, netting virtual inventory and leaving only bounded rounding obligations.
        if (p.liquidity != 0) {
            poolManager.modifyLiquidity(
                key, ModifyLiquidityParams(p.lower, p.upper, int256(uint256(p.liquidity)), LP_SALT), ""
            );
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _requirePool(key);
        RingLPPlanner.Plan memory p = _active;
        if (p.start == 0) revert UnexpectedFill();
        int128 input = params.zeroForOne ? delta.amount0() : delta.amount1();
        int128 output = params.zeroForOne ? delta.amount1() : delta.amount0();
        if (int256(input) != -SafeCast.toInt256(p.amountIn) || int256(output) != SafeCast.toInt256(p.amountOut)) {
            revert UnexpectedFill();
        }
        (uint160 end,,,) = poolManager.getSlot0(configuredPoolId);
        if (end != p.end) revert UnexpectedFill();
        if (p.liquidity != 0) {
            poolManager.modifyLiquidity(
                key, ModifyLiquidityParams(p.lower, p.upper, -int256(uint256(p.liquidity)), LP_SALT), ""
            );
        }
        _donateCreditsThenResolve(key, params.zeroForOne);
        uint256 loss0 = _chargeRounding(key.currency0, _balance0Before);
        uint256 loss1 = _chargeRounding(key.currency1, _balance1Before);
        if (poolManager.getLiquidity(configuredPoolId) == 0) revert UnexpectedLiquidity();
        delete _active;
        delete _balance0Before;
        delete _balance1Before;
        delete _activeDonationLimit;
        jitLockFor(configuredPoolId).clear();
        emit RingBackedSwap(configuredPoolId, params.zeroForOne, p.amountIn, p.amountOut, loss0, loss1);
        return (IHooks.afterSwap.selector, 0);
    }

    function _donateCreditsThenResolve(PoolKey calldata key, bool zeroForOne) private {
        int256 d0 = poolManager.currencyDelta(address(this), key.currency0);
        int256 d1 = poolManager.currencyDelta(address(this), key.currency1);
        uint256 reward0 = d0 > 0 ? SafeCast.toUint256(d0) : 0;
        uint256 reward1 = d1 > 0 ? SafeCast.toUint256(d1) : 0;
        uint256 limit0 = zeroForOne ? _activeDonationLimit : MAX_ROUNDING_LOSS;
        uint256 limit1 = zeroForOne ? MAX_ROUNDING_LOSS : _activeDonationLimit;
        if (reward0 > limit0 || reward1 > limit1) revert RoundingLossExceeded();
        if (reward0 != 0 || reward1 != 0) poolManager.donate(key, reward0, reward1, "");
        _resolve(key.currency0);
        _resolve(key.currency1);
    }

    function _findHybridPlan(
        uint160 start,
        uint128 baseLiquidity,
        int256 specified,
        bool forward,
        int24 spacing,
        address[] memory tokens,
        address[] memory pairs
    ) private view returns (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory best) {
        uint256 maxJit = uint256(type(uint128).max) - baseLiquidity;
        uint256 candidate = uint256(baseLiquidity);
        int256 previousDiff;
        uint256 previousCandidate;
        uint256 bestDifference = type(uint256).max;
        uint256 surplusDifference = type(uint256).max;
        uint256 surplusRingIn;
        uint256 surplusRingOut;
        RingLPPlanner.Plan memory surplus;
        uint256 lower;
        uint256 upper;
        for (uint256 i; i < 32 && candidate <= maxJit; ++i) {
            (uint256 ri, uint256 ro, RingLPPlanner.Plan memory p, int256 diff) = _hybridCandidate(
                start, baseLiquidity, SafeCast.toUint128(candidate), specified, forward, spacing, tokens, pairs
            );
            uint256 difference = diff < 0 ? SafeCast.toUint256(-diff) : SafeCast.toUint256(diff);
            if (difference < bestDifference) {
                (bestDifference, ringIn, ringOut, best) = (difference, ri, ro, p);
            }
            if (diff <= 0 && difference < surplusDifference) {
                (surplusDifference, surplusRingIn, surplusRingOut, surplus) = (difference, ri, ro, p);
            }
            if (previousCandidate != 0 && (diff == 0 || (diff < 0) != (previousDiff < 0))) {
                lower = previousCandidate;
                upper = candidate;
                break;
            }
            previousCandidate = candidate;
            previousDiff = diff;
            if (candidate > maxJit / 2) break;
            candidate *= 2;
        }
        for (uint256 i; i < 64 && lower + 1 < upper; ++i) {
            uint256 middle = lower + (upper - lower) / 2;
            (uint256 ri, uint256 ro, RingLPPlanner.Plan memory p, int256 diff) = _hybridCandidate(
                start, baseLiquidity, SafeCast.toUint128(middle), specified, forward, spacing, tokens, pairs
            );
            uint256 difference = diff < 0 ? SafeCast.toUint256(-diff) : SafeCast.toUint256(diff);
            if (difference < bestDifference) {
                (bestDifference, ringIn, ringOut, best) = (difference, ri, ro, p);
            }
            if (diff <= 0 && difference < surplusDifference) {
                (surplusDifference, surplusRingIn, surplusRingOut, surplus) = (difference, ri, ro, p);
            }
            if ((diff < 0) == (previousDiff < 0)) {
                lower = middle;
                previousDiff = diff;
            } else {
                upper = middle;
            }
        }
        if (surplus.liquidity != 0 && surplusDifference <= _inputQuantum(tokens, pairs, surplusRingOut)) {
            (ringIn, ringOut, best) = (surplusRingIn, surplusRingOut, surplus);
        } else if (best.liquidity == 0 || bestDifference > MAX_ROUNDING_LOSS) {
            (best.end, best.amountIn, best.amountOut) =
                RingLPPlanner.simulate(start, baseLiquidity, specified, forward, spacing);
            best.start = start;
            best.liquidity = 0;
            ringIn = 0;
            ringOut = 0;
        }
    }

    function _inputQuantum(address[] memory tokens, address[] memory pairs, uint256 output)
        private
        view
        returns (uint256)
    {
        uint256 current = _amounts(tokens, pairs, SafeCast.toInt256(output))[0];
        uint256 next = _amounts(tokens, pairs, SafeCast.toInt256(output + 1))[0];
        return next - current + MAX_ROUNDING_LOSS;
    }

    function _hybridCandidate(
        uint160 start,
        uint128 baseLiquidity,
        uint128 jitLiquidity,
        int256 specified,
        bool forward,
        int24 spacing,
        address[] memory tokens,
        address[] memory pairs
    ) private view returns (uint256 ringIn, uint256 ringOut, RingLPPlanner.Plan memory p, int256 difference) {
        uint256 jitIn;
        uint256 jitOut;
        (p, jitIn, jitOut) =
            RingLPPlanner.planAtCurrent(start, baseLiquidity, jitLiquidity, specified, forward, spacing);
        if (jitOut == 0 || jitOut > type(uint96).max) revert UnexpectedFill();
        uint256[] memory amounts = _amounts(tokens, pairs, SafeCast.toInt256(jitOut));
        ringIn = amounts[0];
        ringOut = amounts[amounts.length - 1];
        difference = SafeCast.toInt256(ringIn) - SafeCast.toInt256(jitIn);
    }

    function _requireFullRange(PoolKey calldata key, ModifyLiquidityParams calldata params) private view {
        _requirePool(key);
        if (
            params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
        ) revert FullRangeLiquidityOnly();
    }

    function _resolve(Currency currency) private {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        uint256 amount = SafeCast.toUint256(delta < 0 ? -delta : delta);
        if (amount > MAX_ROUNDING_LOSS) revert RoundingLossExceeded();
        if (delta < 0) _settle(currency, address(this), amount);
        else if (delta > 0) _take(currency, address(this), amount);
    }

    function _chargeRounding(Currency currency, uint256 beforeBalance) private returns (uint256 loss) {
        uint256 afterBalance = currency.balanceOfSelf();
        if (afterBalance > beforeBalance) revert UnexpectedTokenDelta();
        loss = beforeBalance - afterBalance;
        if (loss > MAX_ROUNDING_LOSS) revert RoundingLossExceeded();
        roundingReserve[currency] -= loss;
    }

    function _pay(Currency currency, address, uint256 amount) internal override {
        currency.transfer(address(poolManager), amount);
    }

    function _requirePool(PoolKey calldata key) private view {
        if (!initialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(configuredPoolId)) revert InvalidPool();
    }

    function _requireCurrency(Currency currency) private view {
        if (
            !initialized
                || (Currency.unwrap(currency) != Currency.unwrap(_key.currency0)
                    && Currency.unwrap(currency) != Currency.unwrap(_key.currency1))
        ) revert InvalidPool();
    }

    function _requireBuffers() private view {
        if (roundingReserve[_key.currency0] < MIN_BUFFER || roundingReserve[_key.currency1] < MIN_BUFFER) {
            revert InsufficientRoundingBuffer();
        }
    }

    function _route(bool forward) private view returns (address[] memory tokens, address[] memory pairs) {
        uint256 n = _path.length;
        tokens = new address[](n);
        pairs = new address[](n - 1);
        for (uint256 i; i < n; ++i) {
            tokens[i] = _path[forward ? i : n - 1 - i];
        }
        for (uint256 i; i < n - 1; ++i) {
            pairs[i] = _pairs[forward ? i : n - 2 - i];
        }
    }

    function _reserves(address pair, address input, address output)
        private
        view
        returns (uint256 rIn, uint256 rOut, bool forward)
    {
        address t0 = ISwapV2Pair(pair).token0();
        address t1 = ISwapV2Pair(pair).token1();
        (uint112 r0, uint112 r1,) = ISwapV2Pair(pair).getReserves();
        if (input == t0 && output == t1) return (r0, r1, true);
        if (input == t1 && output == t0) return (r1, r0, false);
        revert InvalidRoute();
    }

    function _amounts(address[] memory tokens, address[] memory pairs, int256 specified)
        private
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](tokens.length);
        if (specified < 0) {
            amounts[0] = SafeCast.toUint256(-specified);
            for (uint256 i; i < pairs.length; ++i) {
                (uint256 rIn, uint256 rOut,) = _reserves(pairs[i], tokens[i], tokens[i + 1]);
                amounts[i + 1] = FewV2Math.getAmountOut(amounts[i], rIn, rOut);
            }
        } else {
            amounts[amounts.length - 1] = SafeCast.toUint256(specified);
            for (uint256 i = pairs.length; i > 0; --i) {
                (uint256 rIn, uint256 rOut,) = _reserves(pairs[i - 1], tokens[i - 1], tokens[i]);
                amounts[i - 1] = FewV2Math.getAmountIn(amounts[i], rIn, rOut);
            }
        }
    }

    function _execute(bool forward, int256 specified, uint256 ringIn, uint256 ringOut) private {
        (address[] memory tokens, address[] memory pairs) = _route(forward);
        uint256[] memory amounts = _amounts(tokens, pairs, specified);
        if (amounts[0] != ringIn || amounts[amounts.length - 1] != ringOut) revert UnexpectedFill();
        address input = Currency.unwrap(forward ? _key.currency0 : _key.currency1);
        if (IFewWrappedToken(tokens[0]).token() != input) revert InvalidRoute();
        uint256 rawBefore = IERC20(input).balanceOf(address(this));
        uint256 fwBefore = IERC20(tokens[0]).balanceOf(address(this));
        IERC20(input).forceApprove(tokens[0], ringIn);
        uint256 minted = IFewWrappedToken(tokens[0]).wrap(ringIn);
        if (
            minted != ringIn || IERC20(tokens[0]).balanceOf(address(this)) != fwBefore + ringIn
                || IERC20(input).balanceOf(address(this)) != rawBefore - ringIn
        ) revert UnexpectedTokenDelta();
        for (uint256 i; i < pairs.length; ++i) {
            (,, bool orientation) = _reserves(pairs[i], tokens[i], tokens[i + 1]);
            uint256 inBefore = IERC20(tokens[i]).balanceOf(address(this));
            uint256 outBefore = IERC20(tokens[i + 1]).balanceOf(address(this));
            IERC20(tokens[i]).safeTransfer(pairs[i], amounts[i]);
            ISwapV2Pair(pairs[i])
                .swap(orientation ? 0 : amounts[i + 1], orientation ? amounts[i + 1] : 0, address(this), "");
            if (
                IERC20(tokens[i]).balanceOf(address(this)) != inBefore - amounts[i]
                    || IERC20(tokens[i + 1]).balanceOf(address(this)) != outBefore + amounts[i + 1]
            ) revert UnexpectedTokenDelta();
        }
        address fwOut = tokens[tokens.length - 1];
        address output = Currency.unwrap(forward ? _key.currency1 : _key.currency0);
        if (IFewWrappedToken(fwOut).token() != output) revert InvalidRoute();
        rawBefore = IERC20(output).balanceOf(address(this));
        fwBefore = IERC20(fwOut).balanceOf(address(this));
        uint256 redeemed = IFewWrappedToken(fwOut).unwrap(ringOut);
        if (
            redeemed != ringOut || IERC20(output).balanceOf(address(this)) != rawBefore + ringOut
                || IERC20(fwOut).balanceOf(address(this)) != fwBefore - ringOut
        ) revert UnexpectedTokenDelta();
    }
}
