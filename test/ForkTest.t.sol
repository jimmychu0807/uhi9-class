// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract ForkTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDC_WHALE = 0x55FE002aefF02F77364de339a1292923A15844B8;

    uint256 forkId;

    modifier forked() {
        forkId = vm.createFork(vm.envString("MAINNET_RPC_URL"));
        vm.selectFork(forkId);
        _;
    }

    function testUSDCBalanceForked() public forked {
        uint256 balance = IERC20(USDC).balanceOf(USDC_WHALE);
        console.log("Whale balance (USDC):", balance / 1e6);
        assertGt(balance, 100_000 * 1e6, "whale should hv larger balance");
    }
}
