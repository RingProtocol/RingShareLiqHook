// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFewFactory} from "../../src/interfaces/external/IFewFactory.sol";

contract RingHookTestToken is ERC20 {
    constructor(address recipient, uint256 supply) ERC20("Ring Hook Test Token", "RHT") {
        _mint(recipient, supply);
    }
}

interface IWETH9Deposit is IERC20 {
    function deposit() external payable;
}

interface IFewV2SeedFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IFewWrappedSeedToken is IERC20 {
    function wrap(uint256 amount) external returns (uint256);
}

interface IFewV2SeedPair {
    function mint(address to) external returns (uint256 liquidity);
}

/// @notice Deploys a disposable 18-decimal test token and seeds a direct
///         fwWETH/fwTestToken FewV2 pair for Sepolia integration testing.
contract SeedRingTestPool is Script {
    using SafeERC20 for IERC20;

    function run() external {
        IFewFactory fewFactory = IFewFactory(vm.envAddress("FEW_FACTORY_ADDR"));
        IFewV2SeedFactory dex = IFewV2SeedFactory(vm.envAddress("FEW_V2_FACTORY_ADDR"));
        IWETH9Deposit weth = IWETH9Deposit(vm.envAddress("WETH_ADDR"));
        address expectedFwWeth = vm.envAddress("FW_WETH_ADDR");
        uint256 wethAmount = vm.envOr("RING_WETH_AMOUNT", uint256(1 ether));
        uint256 tokenAmount = vm.envOr("RING_TEST_TOKEN_AMOUNT", uint256(1_000_000 ether));
        uint256 tokenSupply = vm.envOr("TEST_TOKEN_SUPPLY", uint256(1_000_000_000 ether));
        require(wethAmount != 0 && tokenAmount != 0, "zero seed amount");
        require(tokenSupply >= tokenAmount, "supply below seed amount");

        vm.startBroadcast();
        RingHookTestToken token = new RingHookTestToken(msg.sender, tokenSupply);
        address fwToken = fewFactory.createToken(address(token));
        address fwWeth = fewFactory.getWrappedToken(address(weth));
        require(fwWeth == expectedFwWeth && fwWeth != address(0), "unexpected fwWETH");

        address pair = dex.getPair(fwWeth, fwToken);
        if (pair == address(0)) pair = dex.createPair(fwWeth, fwToken);
        require(pair != address(0), "pair creation failed");

        weth.deposit{value: wethAmount}();
        IERC20(address(weth)).forceApprove(fwWeth, wethAmount);
        IERC20(address(token)).forceApprove(fwToken, tokenAmount);
        require(IFewWrappedSeedToken(fwWeth).wrap(wethAmount) == wethAmount, "fwWETH wrap mismatch");
        require(IFewWrappedSeedToken(fwToken).wrap(tokenAmount) == tokenAmount, "fwToken wrap mismatch");

        IERC20(fwWeth).safeTransfer(pair, wethAmount);
        IERC20(fwToken).safeTransfer(pair, tokenAmount);
        uint256 liquidity = IFewV2SeedPair(pair).mint(msg.sender);
        require(liquidity != 0, "zero LP minted");
        vm.stopBroadcast();

        console2.log("TEST_TOKEN_ADDR", address(token));
        console2.log("FW_TEST_TOKEN_ADDR", fwToken);
        console2.log("FW_WETH_ADDR", fwWeth);
        console2.log("FEW_V2_PAIR_ADDR", pair);
        console2.log("FEW_V2_LP_MINTED", liquidity);
        if (address(weth) < address(token)) {
            console2.log("TOKEN_A_ADDR", address(weth));
            console2.log("TOKEN_B_ADDR", address(token));
            console2.log("FW_PATH currency0", fwWeth);
            console2.log("FW_PATH currency1", fwToken);
            console2.log("WETH_TO_TEST_ZERO_FOR_ONE", true);
        } else {
            console2.log("TOKEN_A_ADDR", address(token));
            console2.log("TOKEN_B_ADDR", address(weth));
            console2.log("FW_PATH currency0", fwToken);
            console2.log("FW_PATH currency1", fwWeth);
            console2.log("WETH_TO_TEST_ZERO_FOR_ONE", false);
        }
    }
}
