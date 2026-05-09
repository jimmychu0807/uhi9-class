// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwapMath} from "@uniswap/v4-core/src/libraries/SwapMath.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

contract InternalSwapPool is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct ClaimableFees {
        uint256 amount0;
        uint256 amount1;
    }

    /// Min threshold for donations
    uint256 public constant DONATE_THRESHOLD_MIN = 0.0001 ether;
    /// The native token address
    address public immutable nativeToken;

    mapping(PoolId _poolId => ClaimableFees _fees) internal _poolFees;

    constructor(address _poolManager, address _nativeToken) BaseHook(IPoolManager(_poolManager)) {
        nativeToken = _nativeToken;
    }

    function poolFees(PoolKey calldata _poolKey) public view returns (ClaimableFees memory) {
        return _poolFees[_poolKey.toId()];
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function depositFees(PoolKey calldata _poolKey, uint256 _amount0, uint256 _amount1) public {
        _poolFees[_poolKey.toId()].amount0 += _amount0;
        _poolFees[_poolKey.toId()].amount1 += _amount1;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4 selector_, BeforeSwapDelta beforeSwapDelta_, uint24 swapFee_)
    {
        PoolId poolId = key.toId();

        if (params.zeroForOne && _poolFees[poolId].amount1 != 0) {
            uint256 tokenIn;
            uint256 ethOut;

            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

            if (params.amountSpecified >= 0) {
                uint256 amountSpecified = (uint256(params.amountSpecified) > _poolFees[poolId].amount1)
                    ? _poolFees[poolId].amount1
                    : uint256(params.amountSpecified);

                (, ethOut, tokenIn,) = SwapMath.computeSwapStep({
                    sqrtPriceCurrentX96: sqrtPriceX96,
                    sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                    liquidity: poolManager.getLiquidity(poolId),
                    amountRemaining: int256(amountSpecified),
                    feePips: 0
                });

                beforeSwapDelta_ = toBeforeSwapDelta(-int128(int256(tokenIn)), int128(int256(ethOut)));
            } else {
                (, ethOut, tokenIn,) = SwapMath.computeSwapStep({
                    sqrtPriceCurrentX96: sqrtPriceX96,
                    sqrtPriceTargetX96: params.sqrtPriceLimitX96,
                    liquidity: poolManager.getLiquidity(poolId),
                    amountRemaining: int256(_poolFees[poolId].amount1),
                    feePips: 0
                });

                if (ethOut > uint256(-params.amountSpecified)) {
                    uint256 percentage = (uint256(-params.amountSpecified) * 1e18) / ethOut;
                    tokenIn = (tokenIn * percentage) / 1e18;
                }

                beforeSwapDelta_ = toBeforeSwapDelta(int128(int256(ethOut)), -int128(int256(tokenIn)));
            }

            _poolFees[poolId].amount0 += ethOut;
            _poolFees[poolId].amount1 -= tokenIn;

            poolManager.sync(key.currency0);
            poolManager.sync(key.currency1);

            poolManager.take(key.currency0, address(this), ethOut);
            key.currency1.settle(poolManager, address(this), tokenIn, false);
        }

        selector_ = IHooks.beforeSwap.selector;
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4 selector_, int128 hookDeltaUnspecified_) {
        Currency swapFeeCurrency = (params.amountSpecified < 0) == params.zeroForOne ? key.currency1 : key.currency0;

        int128 swapAmount = params.amountSpecified < 0 == params.zeroForOne ? delta.amount1() : delta.amount0();

        uint256 swapFee = uint256(uint128(swapAmount < 0 ? -swapAmount : swapAmount)) * 99 / 100;

        depositFees(key, params.zeroForOne ? swapFee : 0, params.zeroForOne ? 0 : swapFee);

        swapFeeCurrency.take(poolManager, address(this), swapFee, false);

        hookDeltaUnspecified_ = -int128(int256(swapFee));

        _distributeFees(key);
        selector_ = IHooks.afterSwap.selector;
    }

    function _distributeFees(PoolKey calldata _poolKey) internal {
        PoolId poolId = _poolKey.toId();
        uint256 donateAmount = _poolFees[poolId].amount0;

        if (donateAmount < DONATE_THRESHOLD_MIN) {
            return;
        }

        BalanceDelta delta = poolManager.donate(_poolKey, donateAmount, 0, "");

        if (delta.amount0() < 0) {
            _poolKey.currency0.settle(poolManager, address(this), uint256(uint128(-delta.amount0())), false);
        }

        _poolFees[poolId].amount0 -= donateAmount;
    }
}
