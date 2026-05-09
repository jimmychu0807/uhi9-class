// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

contract CSMM is BaseHook {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    error AddLiquidityThroughHook();

    event HookSwap(
        bytes32 indexed id,
        address indexed sender,
        int128 amt0,
        int128 amt1,
        uint128 hookLPfeeAmt0,
        uint128 hookLPfeeAmt1
    );

    event HookModifyLiquidity(bytes32 indexed id, address indexed sender, int128 amt0, int128 amt1);

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // Don't allow adding liquidity normally
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Override how swaps are done
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // Allow beforeSwap to return a custom delta
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Disable adding liquidity thru the PM (pool manager)
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityThroughHook();
    }

    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        // when you do something to interact with the PM, need to call unlock()
        // the contract need to implement `unlockCallback()` also
        poolManager.unlock(abi.encode(CallbackData(amountEach, key.currency0, key.currency1, msg.sender)));

        emit HookModifyLiquidity(
            PoolId.unwrap(key.toId()), address(this), int128(uint128(amountEach)), int128(uint128(amountEach))
        );
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // pay the 1) specified currency to the pool manager from 2) the specified payer
        callbackData.currency0
            .settle(
                poolManager,
                callbackData.sender,
                callbackData.amountEach,
                false // burn = false i.e. we're transferring tokens, not burning ERC-6909 claim tokens
            );

        callbackData.currency1
            .settle(
                poolManager,
                callbackData.sender,
                callbackData.amountEach,
                false // burn = false i.e. we're transferring tokens, not burning ERC-6909 claim tokens
            );

        // The token transfer can only interact with the PM, i.e. one side has to be the PM.

        // pay the 1) specified currency from the pool manager to 2) the specified payer
        callbackData.currency0
            .take(
                poolManager,
                address(this),
                callbackData.amountEach,
                true // mint = true i.e. this is a ERC-6909 claim token, not actual transfer
            );

        callbackData.currency1
            .take(
                poolManager,
                address(this),
                callbackData.amountEach,
                true // mint = true i.e. this is a ERC-6909 claim token, not actual transfer
            );

        return "";
    }

    // Override to use the curve: x + y = k, instead of x * y = k
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool isExactInput = params.amountSpecified < 0;

        // 4 types of swap:
        //   - whether `params.zeroForOne` is true
        //   - whether `isExactInput` is true

        // BalanceSwapDelta is packed with two `int128` values.

        int128 absInAmt;
        int128 absOutAmt;
        BeforeSwapDelta beforeSwapDelta;

        // formulate the beforeSwapDelta structure
        if (isExactInput) {
            absInAmt = int128(-params.amountSpecified);
            absOutAmt = absInAmt;
            beforeSwapDelta = toBeforeSwapDelta(absInAmt, -absOutAmt);
        } else {
            absOutAmt = int128(params.amountSpecified);
            absInAmt = absOutAmt;
            beforeSwapDelta = toBeforeSwapDelta(-absInAmt, absOutAmt);
        }

        if (params.zeroForOne) {
            key.currency0
                .take(
                    poolManager,
                    address(this),
                    uint256(uint128(absInAmt)),
                    true // mint ERC-6909
                );

            key.currency1
                .settle(
                    poolManager,
                    address(this),
                    uint256(uint128(absOutAmt)),
                    true // burn from ERC-6909
                );

            emit HookSwap(PoolId.unwrap(key.toId()), sender, -absInAmt, absOutAmt, 0, 0);
        } else {
            key.currency0
                .settle(
                    poolManager,
                    address(this),
                    uint256(uint128(absOutAmt)),
                    true // burn from ERC-6909
                );
            key.currency1
                .take(
                    poolManager,
                    address(this),
                    uint256(uint128(absInAmt)),
                    true // burn from ERC-6909
                );

            emit HookSwap(PoolId.unwrap(key.toId()), sender, absInAmt, -absOutAmt, 0, 0);
        }

        return (this.beforeSwap.selector, beforeSwapDelta, 0);
    }
}
