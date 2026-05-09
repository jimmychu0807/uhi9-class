// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {CSMM} from "../src/CSMM.sol";

contract CSMMTest is Test, Deployers {
    using PoolIdLibrary for PoolId;
    using CurrencyLibrary for Currency;

    // constants
    uint256 constant INIT_LIQUIDITY = 1000e18;

    CSMM hook;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address hookAddress = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
        );

        console.log("hookAddress: %s", hookAddress);

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
}
