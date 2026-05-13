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

    function test_orderExecute_zeroForOne() public {
        int24 tick = 100;
        uint256 amount = 1 ether;
        bool zeroForOne = true;

        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);

        SwapParams memory params = SwapParams({
            zeroForOne: !zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 pendingTokensForPosition = hook.pendingOrders(key.toId(), tick, zeroForOne);
        assertEq(pendingTokensForPosition, 0);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokens = hook.claimableOutputTokens(orderId);
        uint256 hookContractToken1Balance = token1.balanceOf(address(hook));
        assertEq(claimableOutputTokens, hookContractToken1Balance);

        uint256 originalToken1Balance = token1.balanceOf(address(this));
        hook.redeem(key, tick, zeroForOne, amount);
        uint256 newToken1Balance = token1.balanceOf(address(this));

        assertEq(newToken1Balance - originalToken1Balance, claimableOutputTokens);
    }

    function test_multiple_orderExecute_zeroForOne_onlyOne() public {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 amount = 0.01 ether;

        hook.placeOrder(key, 0, true, amount);
        hook.placeOrder(key, 60, true, amount);

        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertEq(currentTick, 0);

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -0.1 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), 0, true);
        assertEq(tokensLeftToSell, 0);

        tokensLeftToSell = hook.pendingOrders(key.toId(), 60, true);
        assertEq(tokensLeftToSell, amount);
    }

    function test_multiple_orderExecute_zeroForOne_both() public {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 amount = 0.01 ether;

        hook.placeOrder(key, 0, true, amount);
        hook.placeOrder(key, 60, true, amount);

        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertEq(currentTick, 0);

        SwapParams memory params = SwapParams({
            zeroForOne: false, amountSpecified: -0.5 ether, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), 0, true);
        assertEq(tokensLeftToSell, 0);

        tokensLeftToSell = hook.pendingOrders(key.toId(), 60, true);
        assertEq(tokensLeftToSell, 0);
    }
}
