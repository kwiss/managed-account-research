// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {UniswapSwapPolicy} from "../src/policies/UniswapSwapPolicy.sol";

contract UniswapSwapPolicyTest is Test {
    UniswapSwapPolicy public policy;

    address public account = address(0xACC);
    address public router = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address public tokenA = address(0xA);
    address public tokenB = address(0xB);

    bytes4 public constant EXACT_INPUT_SINGLE_SELECTOR =
        bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))"));

    function setUp() public {
        policy = new UniswapSwapPolicy();
    }

    function _buildSwapCalldata(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address recipient,
        uint256 amountIn,
        uint256 amountOutMin,
        uint160 sqrtPriceLimit
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            EXACT_INPUT_SINGLE_SELECTOR, tokenIn, tokenOut, fee, recipient, amountIn, amountOutMin, sqrtPriceLimit
        );
    }

    // ─── Valid Swap Tests ────────────────────────────────────────────────────

    function test_checkAction_validSwap() public {
        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            tokenIn: tokenA,
            tokenOut: tokenB,
            recipient: account,
            feeTier: 3000,
            maxDailyVolume: 100 ether,
            active: true
        });

        vm.prank(account);
        policy.setSwapConfig(router, config);

        bytes memory callData = _buildSwapCalldata(tokenA, tokenB, 3000, account, 1 ether, 0, 0);

        // H-01: Must call as account
        vm.prank(account);
        assertTrue(policy.checkAction(account, router, 0, callData));
    }

    function test_checkAction_validSwap_anyToken() public {
        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            tokenIn: address(0), // any
            tokenOut: address(0), // any
            recipient: account,
            feeTier: 0, // any
            maxDailyVolume: 0, // unlimited
            active: true
        });

        vm.prank(account);
        policy.setSwapConfig(router, config);

        bytes memory callData = _buildSwapCalldata(tokenA, tokenB, 500, account, 50 ether, 0, 0);

        vm.prank(account);
        assertTrue(policy.checkAction(account, router, 0, callData));
    }

    // ─── Invalid Swap Tests ──────────────────────────────────────────────────

    function test_checkAction_revert_policyNotConfigured() public {
        bytes memory callData = _buildSwapCalldata(tokenA, tokenB, 3000, account, 1 ether, 0, 0);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapSwapPolicy.PolicyNotConfigured.selector, account, router)
        );
        policy.checkAction(account, router, 0, callData);
    }

    function test_checkAction_revert_invalidTokenIn() public {
        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            tokenIn: tokenA,
            tokenOut: tokenB,
            recipient: account,
            feeTier: 3000,
            maxDailyVolume: 0,
            active: true
        });

        vm.prank(account);
        policy.setSwapConfig(router, config);

        address wrongToken = address(0xBAD);
        bytes memory callData = _buildSwapCalldata(wrongToken, tokenB, 3000, account, 1 ether, 0, 0);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(UniswapSwapPolicy.InvalidTokenIn.selector, wrongToken, tokenA));
        policy.checkAction(account, router, 0, callData);
    }

    function test_checkAction_revert_invalidTokenOut() public {
        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            tokenIn: tokenA,
            tokenOut: tokenB,
            recipient: account,
            feeTier: 3000,
            maxDailyVolume: 0,
            active: true
        });

        vm.prank(account);
        policy.setSwapConfig(router, config);

        address wrongToken = address(0xBAD);
        bytes memory callData = _buildSwapCalldata(tokenA, wrongToken, 3000, account, 1 ether, 0, 0);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(UniswapSwapPolicy.InvalidTokenOut.selector, wrongToken, tokenB));
        policy.checkAction(account, router, 0, callData);
    }

    function test_checkAction_revert_invalidRecipient() public {
        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            tokenIn: tokenA,
            tokenOut: tokenB,
            recipient: account,
            feeTier: 3000,
            maxDailyVolume: 0,
            active: true
        });

        vm.prank(account);
        policy.setSwapConfig(router, config);

        address wrongRecipient = address(0xBAD);
        bytes memory callData = _buildSwapCalldata(tokenA, tokenB, 3000, wrongRecipient, 1 ether, 0, 0);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(UniswapSwapPolicy.InvalidRecipient.selector, wrongRecipient, account));
        policy.checkAction(account, router, 0, callData);
    }

    function test_checkAction_revert_invalidFeeTier() public {
        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            tokenIn: tokenA,
            tokenOut: tokenB,
            recipient: account,
            feeTier: 3000,
            maxDailyVolume: 0,
            active: true
        });

        vm.prank(account);
        policy.setSwapConfig(router, config);

        bytes memory callData = _buildSwapCalldata(tokenA, tokenB, 500, account, 1 ether, 0, 0);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(UniswapSwapPolicy.InvalidFeeTier.selector, uint24(500), uint24(3000)));
        policy.checkAction(account, router, 0, callData);
    }

    function test_checkAction_revert_dailyVolumeExceeded() public {
        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            tokenIn: tokenA,
            tokenOut: tokenB,
            recipient: account,
            feeTier: 3000,
            maxDailyVolume: 10 ether,
            active: true
        });

        vm.prank(account);
        policy.setSwapConfig(router, config);

        // First swap OK
        bytes memory callData = _buildSwapCalldata(tokenA, tokenB, 3000, account, 8 ether, 0, 0);
        vm.prank(account);
        policy.checkAction(account, router, 0, callData);

        // Second swap exceeds daily limit
        bytes memory callData2 = _buildSwapCalldata(tokenA, tokenB, 3000, account, 5 ether, 0, 0);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(UniswapSwapPolicy.DailyVolumeLimitExceeded.selector, 13 ether, 10 ether)
        );
        policy.checkAction(account, router, 0, callData2);
    }

    function test_checkAction_dailyVolumeResets() public {
        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            tokenIn: tokenA,
            tokenOut: tokenB,
            recipient: account,
            feeTier: 3000,
            maxDailyVolume: 10 ether,
            active: true
        });

        vm.prank(account);
        policy.setSwapConfig(router, config);

        bytes memory callData = _buildSwapCalldata(tokenA, tokenB, 3000, account, 8 ether, 0, 0);
        vm.prank(account);
        policy.checkAction(account, router, 0, callData);

        // Warp to next day
        vm.warp(block.timestamp + 1 days);

        // Should be allowed again
        vm.prank(account);
        assertTrue(policy.checkAction(account, router, 0, callData));
    }

    function test_checkAction_revert_invalidCalldata() public {
        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            tokenIn: tokenA,
            tokenOut: tokenB,
            recipient: account,
            feeTier: 3000,
            maxDailyVolume: 0,
            active: true
        });

        vm.prank(account);
        policy.setSwapConfig(router, config);

        vm.prank(account);
        vm.expectRevert(UniswapSwapPolicy.InvalidCalldata.selector);
        policy.checkAction(account, router, 0, hex"deadbeef");
    }

    // ─── Test: H-01 unauthorized caller ──────────────────────────────────────

    function test_checkAction_revert_unauthorizedCaller() public {
        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            tokenIn: tokenA,
            tokenOut: tokenB,
            recipient: account,
            feeTier: 3000,
            maxDailyVolume: 10 ether,
            active: true
        });

        vm.prank(account);
        policy.setSwapConfig(router, config);

        bytes memory callData = _buildSwapCalldata(tokenA, tokenB, 3000, account, 1 ether, 0, 0);

        // Random caller should be rejected
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(UniswapSwapPolicy.UnauthorizedCaller.selector);
        policy.checkAction(account, router, 0, callData);
    }
}
