// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {RingBackedBase} from "./RingBackedBase.sol";

interface IPositionManagerLike {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
}

interface IPermit2Like {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IWETHLike {
    function deposit() external payable;
}

/// @notice Mints the permanent full-range v4 position as an NFT owned by the broadcaster.
contract AddBasePosition is RingBackedBase {
    using SafeERC20 for IERC20;

    uint8 private constant MINT_POSITION = 0x02;
    uint8 private constant CLOSE_CURRENCY = 0x12;

    function run() external {
        PoolKey memory key = _key();
        address posmAddress = vm.envAddress("V4_POSITION_MANAGER_ADDR");
        address permit2Address = vm.envAddress("PERMIT2_ADDR");
        IPositionManagerLike posm = IPositionManagerLike(posmAddress);
        require(posmAddress.code.length > 0 && permit2Address.code.length > 0, "missing periphery");

        uint256 amount0 = _amountFor(Currency.unwrap(key.currency0));
        uint256 amount1 = _amountFor(Currency.unwrap(key.currency1));
        uint160 sqrtPriceX96 = uint160(vm.envUint("INITIAL_SQRT_PRICE_X96"));
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
        require(liquidity > 0, "zero liquidity");

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            lower,
            upper,
            uint256(liquidity),
            SafeCast.toUint128(amount0),
            SafeCast.toUint128(amount1),
            msg.sender,
            bytes("")
        );
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        bytes memory actions = abi.encodePacked(MINT_POSITION, CLOSE_CURRENCY, CLOSE_CURRENCY);
        uint256 tokenId = posm.nextTokenId();

        vm.startBroadcast();
        _wrapMissingWeth(key.currency0, amount0);
        _wrapMissingWeth(key.currency1, amount1);
        _approve(key.currency0, permit2Address, posmAddress, amount0);
        _approve(key.currency1, permit2Address, posmAddress, amount1);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 600);
        vm.stopBroadcast();

        console2.log("V4_POSITION_TOKEN_ID", tokenId);
        console2.log("V4_BASE_LIQUIDITY", liquidity);
        console2.log("V4_AMOUNT0_MAX", amount0);
        console2.log("V4_AMOUNT1_MAX", amount1);
    }

    function _amountFor(address token) private view returns (uint256) {
        if (token == vm.envAddress("WETH_ADDR")) return vm.envUint("V4_BASE_WETH_AMOUNT");
        require(token == vm.envAddress("TEST_TOKEN_ADDR"), "unexpected pool token");
        return vm.envUint("V4_BASE_TEST_TOKEN_AMOUNT");
    }

    function _approve(Currency currency, address permit2, address posm, uint256 amount) private {
        address token = Currency.unwrap(currency);
        IERC20(token).forceApprove(permit2, type(uint256).max);
        IPermit2Like(permit2)
            .approve(token, posm, SafeCast.toUint160(amount), SafeCast.toUint48(block.timestamp + 1 hours));
    }

    function _wrapMissingWeth(Currency currency, uint256 amount) private {
        address token = Currency.unwrap(currency);
        if (token != vm.envAddress("WETH_ADDR")) return;
        uint256 balance = IERC20(token).balanceOf(msg.sender);
        if (balance < amount) IWETHLike(token).deposit{value: amount - balance}();
    }
}
