// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {LimitOrderHook} from "../src/LimitOrderHook.sol";

contract LimitOrderHookTest is Test, Deployers, ERC1155Holder {
    using StateLibrary for IPoolManager;

    Currency token0;
    Currency token1;

    LimitOrderHook hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        (token0, token1) = deployMintAndApprove2Currencies();

        address hookAddress = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG));
        deployCodeTo("LimitOrderHook.sol:LimitOrderHook", abi.encode(manager, ""), hookAddress);

        hook = LimitOrderHook(hookAddress);

        IERC20Minimal(Currency.unwrap(token0)).approve(hookAddress, type(uint256).max);
        IERC20Minimal(Currency.unwrap(token1)).approve(hookAddress, type(uint256).max);

        (key,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);

        // Add initial liquidity to the pool

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 10 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_placeOrder() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOfSelf();
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);

        uint256 newBalance = token0.balanceOfSelf();

        assertEq(tickLower, 60);
        assertEq(originalBalance - newBalance, amount);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), orderId);

        assertTrue(orderId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_cancelOrder() public {
        int24 tick = 100;
        uint256 amount = 10 ether;
        bool zeroForOne = true;

        uint256 originalBalance = token0.balanceOfSelf();
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);
        uint256 newBalance = token0.balanceOfSelf();

        assertEq(tickLower, 60);
        assertEq(originalBalance - newBalance, amount);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), orderId);
        assertEq(tokenBalance, amount);

        // cancel the order
        hook.cancelOrder(key, tickLower, zeroForOne, amount);

        uint256 finalBalance = token0.balanceOfSelf();
        assertEq(finalBalance, originalBalance);

        tokenBalance = hook.balanceOf(address(this), orderId);
        assertEq(tokenBalance, 0);
    }
}
