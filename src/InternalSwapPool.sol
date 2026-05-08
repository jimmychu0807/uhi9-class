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

    function depositFees(PoolKey calldata _poolKey, uint256 _amount0, uint256 _amount1) public {
        _poolFees[_poolKey.toId()].amount0 += _amount0;
        _poolFees[_poolKey.toId()].amount1 += _amount1;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4 selector_, BeforeSwapDelta beforeSwapDelta_, uint24 swapFee_)
    {
        selector_ = IHooks.beforeSwap.selector;
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4 selector_, int128 hookDeltaUnspecified_) {
        selector_ = IHooks.afterSwap.selector;
    }

    function _distributeFees(PoolKey calldata _poolKey) internal {}

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
}
