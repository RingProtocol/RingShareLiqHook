// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";

contract TestToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        balanceOf[msg.sender] = type(uint256).max;
    }
    
    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
    
    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DeployTestToken is Script {
    function run() public returns (address token, address fwToken) {
        IFewFactory fewFactory = IFewFactory(vm.envAddress("FEW_FACTORY_ADDR"));
        vm.startBroadcast();
        token = address(new TestToken("Test USD", "TUSD"));
        fwToken = fewFactory.createToken(token);
        vm.stopBroadcast();
        console2.log("TestToken deployed:", token);
        console2.log("fwTestToken deployed:", fwToken);
    }
}
