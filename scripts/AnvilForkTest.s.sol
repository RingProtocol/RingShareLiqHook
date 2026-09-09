// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
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

import {RingShareLiqHook} from "../src/hooks/RingShareLiqHook.sol";
// ── Mocks (same as test/RingShareLiqHook.t.sol) ──────────────────────────

contract TestToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

    contract MockFewWrappedToken is IFewWrappedToken {
        address public immutable token;
        string public name = "fwTEST";
        string public symbol = "fwTEST";
        uint8 public constant decimals = 18;
        uint256 public totalSupply;
        mapping(address => uint256) public balanceOf;
        mapping(address => mapping(address => uint256)) public allowance;

        constructor(address _token) {
            token = _token;
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

    contract MockFewFactory is IFewFactory {
        mapping(address => address) public wrapped;

        function getWrappedToken(address originalToken) public view returns (address wrappedToken) {
            return wrapped[originalToken];
        }

        function createToken(address originalToken) external returns (address wrappedToken) {
            require(wrapped[originalToken] == address(0), "exists");
            MockFewWrappedToken t = new MockFewWrappedToken(originalToken);
            wrapped[originalToken] = address(t);
            return address(t);
        }
    }

    // ── Main entry point ─────────────────────────────────────────────────────

    /// @notice End-to-end anvil-fork integration test: deploy every dependency from scratch,
    ///         run the full hook lifecycle (init → bootstrap → swap → withdraw), and log results.
    ///         Verifies the post-native-ETH-removal build works on a live EVM.
    contract AnvilForkTest is Script {
        using PoolIdLibrary for PoolKey;
        using StateLibrary for IPoolManager;
        using CurrencyLibrary for Currency;
        using SafeCast for uint256;
        using SafeERC20 for IERC20;
        using BalanceDeltaLibrary for BalanceDelta;

        uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
        uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

        function run() public {
            address deployer = msg.sender;
            console2.log("=== RingShareLiqHook Anvil Fork Test ===");
            console2.log("deployer:", deployer);
            console2.log("deployer balance:", deployer.balance);

            vm.startBroadcast();

            // 1. Deploy PoolManager
            PoolManager poolManager = new PoolManager(deployer);
            console2.log("PoolManager deployed:", address(poolManager));

            // 2. Deploy MockFewFactory
            MockFewFactory fewFactory = new MockFewFactory();
            console2.log("FewFactory deployed:", address(fewFactory));

            // 3. Deploy two test tokens
            TestToken tokenA = new TestToken("Ring Test A", "RTA");
            TestToken tokenB = new TestToken("Ring Test B", "RTB");
            tokenA.mint(deployer, 1_000_000 ether);
            tokenB.mint(deployer, 1_000_000 ether);
            console2.log("TokenA deployed:", address(tokenA));
            console2.log("TokenB deployed:", address(tokenB));

            // 4. Create fwTokens
            address fwTokenA = fewFactory.createToken(address(tokenA));
            address fwTokenB = fewFactory.createToken(address(tokenB));
            console2.log("fwTokenA:", fwTokenA);
            console2.log("fwTokenB:", fwTokenB);

            // 5. Deploy AllowlistedFactory pinned to this build's creation code hash
            bytes32 hookCodeHash = keccak256(type(RingShareLiqHook).creationCode);
            bytes32[] memory allowlist = new bytes32[](1);
            allowlist[0] = hookCodeHash;
            AllowlistedFactory factory = new AllowlistedFactory(allowlist);
            console2.log("AllowlistedFactory deployed:", address(factory));
            console2.log("Hook creation code hash:");
            console2.logBytes32(hookCodeHash);

            // 6. Mine CREATE2 salt for the hook flags and deploy via factory
            bytes memory creationCode = type(RingShareLiqHook).creationCode;
            bytes memory constructorArgs = abi.encode(
                IPoolManager(address(poolManager)),
                uint32(500_000),
                deployer,
                IFewFactory(address(fewFactory)),
                IWETH9(address(0))
            );
            bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

            bytes32 salt;
            address predicted;
            for (uint256 i = 0; i < 10_000_000; i++) {
                salt = bytes32(i);
                predicted = Create2.computeAddress(salt, initCodeHash, address(factory));
                if (uint160(predicted) & 0x3FFF == HOOK_FLAGS) break;
            }
            require(uint160(predicted) & 0x3FFF == HOOK_FLAGS, "no salt found");

            address hookAddr = factory.deploy(creationCode, constructorArgs, salt);
            RingShareLiqHook hook = RingShareLiqHook(payable(hookAddr));
            require(hookAddr == predicted, "address mismatch");
            console2.log("RingShareLiqHook deployed:", hookAddr);
            console2.log("hook flags valid:", uint160(hookAddr) & 0x3FFF == HOOK_FLAGS);

            // 7. Build pool key (tokens sorted)
            (Currency c0, Currency c1) = address(tokenA) < address(tokenB)
                ? (Currency.wrap(address(tokenA)), Currency.wrap(address(tokenB)))
                : (Currency.wrap(address(tokenB)), Currency.wrap(address(tokenA)));
            PoolKey memory key =
                PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(hookAddr)});
            PoolId poolId = key.toId();

            // 8. Initialize pool
            int24 tick = hook.initializePool(key, SQRT_PRICE_1_1);
            console2.log("Pool initialized at tick:", tick);

            // 9. Approve underlying -> fwToken (for wrap), and fwToken -> hook (for bootstrap)
            address fw0 = fewFactory.getWrappedToken(Currency.unwrap(c0));
            address fw1 = fewFactory.getWrappedToken(Currency.unwrap(c1));
            IERC20(Currency.unwrap(c0)).approve(fw0, type(uint256).max);
            IERC20(Currency.unwrap(c1)).approve(fw1, type(uint256).max);
            IERC20(fw0).approve(hookAddr, type(uint256).max);
            IERC20(fw1).approve(hookAddr, type(uint256).max);

            // 10. Wrap tokens into fwTokens and bootstrap
            uint256 bootstrapAmount = 10_000 ether;
            IFewWrappedToken(fw0).wrap(bootstrapAmount);
            IFewWrappedToken(fw1).wrap(bootstrapAmount);
            hook.bootstrap(key, bootstrapAmount, bootstrapAmount);
            console2.log("Pool bootstrapped and live");

            (uint256 r0, uint256 r1) = hook.getReserves(key);
            console2.log("reserve0:", r0);
            console2.log("reserve1:", r1);

            // 11. Deploy swap router and execute a test swap
            PoolSwapTest router = new PoolSwapTest(IPoolManager(address(poolManager)));
            IERC20(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
            IERC20(Currency.unwrap(c1)).approve(address(router), type(uint256).max);

            uint256 swapAmount = 1 ether;
            bool zeroForOne = true;

            (uint256 r0Before, uint256 r1Before) = hook.getReserves(key);
            (, int24 tickBefore,,) = IPoolManager(address(poolManager)).getSlot0(poolId);

            BalanceDelta delta = router.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(swapAmount),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            console2.log("=== Swap complete ===");
            console2.log("delta amount0:", delta.amount0());
            console2.log("delta amount1:", delta.amount1());

            (uint256 r0After, uint256 r1After) = hook.getReserves(key);
            (, int24 tickAfter,,) = IPoolManager(address(poolManager)).getSlot0(poolId);
            console2.log("reserve0 before/after:", r0Before, r0After);
            console2.log("reserve1 before/after:", r1Before, r1After);
            console2.log("tick before/after:");
            console2.logInt(tickBefore);
            console2.logInt(tickAfter);

            // 12. Test withdraw
            uint256 withdrawAmount = 100 ether;
            hook.withdraw(key, withdrawAmount, 0, deployer);
            console2.log("=== Withdraw complete ===");
            console2.log("withdrawn fwToken0 balance:", IERC20(fw0).balanceOf(deployer));

            (uint256 r0w, uint256 r1w) = hook.getReserves(key);
            console2.log("reserve0 after withdraw:", r0w);
            console2.log("reserve1 after withdraw:", r1w);

            vm.stopBroadcast();

            console2.log("=== ALL TESTS PASSED ===");
        }
    }
