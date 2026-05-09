// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {CSMM} from "../src/CSMM.sol";

contract CSMMTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    // constants
    uint256 constant INIT_LIQUIDITY = 1000 ether;

    CSMM hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
        );

        deployCodeTo("CSMM.sol", abi.encode(manager), hookAddress);
        hook = CSMM(hookAddress);

        (key,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);

        IERC20Minimal(Currency.unwrap(key.currency0)).approve(hookAddress, INIT_LIQUIDITY);
        IERC20Minimal(Currency.unwrap(key.currency1)).approve(hookAddress, INIT_LIQUIDITY);

        hook.addLiquidity(key, INIT_LIQUIDITY);
    }

    function test_claimTokenBalances() public view {
        uint256 token0ClaimId = CurrencyLibrary.toId(currency0);
        uint256 token1ClaimId = CurrencyLibrary.toId(currency1);

        uint256 token0ClaimsBalance = manager.balanceOf(address(hook), token0ClaimId);

        uint256 token1ClaimsBalance = manager.balanceOf(address(hook), token1ClaimId);

        assertEq(token0ClaimsBalance, INIT_LIQUIDITY);
        assertEq(token1ClaimsBalance, INIT_LIQUIDITY);
    }

    function test_cannotModifyLiquidity() public {
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    function test_swap_exactInput_zeroForOne() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Swap exact input 100 token A
        uint256 balanceOfTokenABefore = key.currency0.balanceOfSelf();
        uint256 balanceOfTokenBBefore = key.currency1.balanceOfSelf();

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            ZERO_BYTES
        );

        uint256 balanceOfTokenAAfter = key.currency0.balanceOfSelf();
        uint256 balanceOfTokenBAfter = key.currency1.balanceOfSelf();

        assertEq(balanceOfTokenABefore - balanceOfTokenAAfter, 10 ether);
        assertEq(balanceOfTokenBAfter - balanceOfTokenBBefore, 10 ether);
    }

    function test_swap_exactOutput_zeroForOne() public {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Swap exact input 100 token A
        uint256 balanceOfTokenABefore = key.currency0.balanceOfSelf();
        uint256 balanceOfTokenBBefore = key.currency1.balanceOfSelf();

        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 10 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings,
            ZERO_BYTES
        );

        uint256 balanceOfTokenAAfter = key.currency0.balanceOfSelf();
        uint256 balanceOfTokenBAfter = key.currency1.balanceOfSelf();

        assertEq(balanceOfTokenABefore - balanceOfTokenAAfter, 10 ether);
        assertEq(balanceOfTokenBAfter - balanceOfTokenBBefore, 10 ether);
    }
}
