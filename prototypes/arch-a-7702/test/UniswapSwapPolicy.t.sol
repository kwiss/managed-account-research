// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {UniswapSwapPolicy} from "../src/policies/UniswapSwapPolicy.sol";

contract UniswapSwapPolicyTest is Test {
    UniswapSwapPolicy policy;

    address account = makeAddr("account");
    address target = makeAddr("uniswapRouter");

    address constant WETH = address(0x1111);
    address constant USDC = address(0x2222);
    address constant DAI = address(0x3333);
    address constant UNKNOWN_TOKEN = address(0x9999);

    uint24 constant FEE_500 = 500;
    uint24 constant FEE_3000 = 3000;
    uint24 constant FEE_INVALID = 100;

    uint256 constant DAILY_LIMIT = 10 ether;

    // exactInputSingle selector
    bytes4 constant EXACT_INPUT_SINGLE = 0x414bf389;

    function setUp() public {
        policy = new UniswapSwapPolicy();

        address[] memory tokensIn = new address[](2);
        tokensIn[0] = WETH;
        tokensIn[1] = USDC;

        address[] memory tokensOut = new address[](2);
        tokensOut[0] = USDC;
        tokensOut[1] = DAI;

        uint24[] memory feeTiers = new uint24[](2);
        feeTiers[0] = FEE_500;
        feeTiers[1] = FEE_3000;

        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            allowedTokensIn: tokensIn,
            allowedTokensOut: tokensOut,
            requiredRecipient: account,
            allowedFeeTiers: feeTiers,
            dailyVolumeLimit: DAILY_LIMIT
        });

        // [C-01] Must call initializePolicy as the account itself
        vm.prank(account);
        policy.initializePolicy(account, config);
    }

    /// @dev Encodes an exactInputSingle call with the given params.
    function _encodeSwap(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address recipient,
        uint256 deadline,
        uint256 amountIn,
        uint256 amountOutMin,
        uint160 sqrtPriceLimitX96
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            EXACT_INPUT_SINGLE,
            tokenIn,
            tokenOut,
            fee,
            recipient,
            deadline,
            amountIn,
            amountOutMin,
            sqrtPriceLimitX96
        );
    }

    function _validSwapData(uint256 amountIn) internal view returns (bytes memory) {
        return _encodeSwap(WETH, USDC, FEE_3000, account, block.timestamp + 1, amountIn, 0, 0);
    }

    // ──────────────────── Valid Swap ────────────────────

    function test_validSwap() public {
        bytes memory data = _validSwapData(1 ether);
        uint256 result = policy.checkAction(bytes32(0), account, target, 0, data);
        assertEq(result, 0);
    }

    // ──────────────────── Wrong tokenIn ────────────────────

    function test_wrongTokenIn_reverts() public {
        bytes memory data = _encodeSwap(
            UNKNOWN_TOKEN, USDC, FEE_3000, account, block.timestamp + 1, 1 ether, 0, 0
        );
        vm.expectRevert(
            abi.encodeWithSelector(UniswapSwapPolicy.TokenInNotAllowed.selector, UNKNOWN_TOKEN)
        );
        policy.checkAction(bytes32(0), account, target, 0, data);
    }

    // ──────────────────── Wrong tokenOut ────────────────────

    function test_wrongTokenOut_reverts() public {
        bytes memory data = _encodeSwap(
            WETH, UNKNOWN_TOKEN, FEE_3000, account, block.timestamp + 1, 1 ether, 0, 0
        );
        vm.expectRevert(
            abi.encodeWithSelector(UniswapSwapPolicy.TokenOutNotAllowed.selector, UNKNOWN_TOKEN)
        );
        policy.checkAction(bytes32(0), account, target, 0, data);
    }

    // ──────────────────── Wrong Recipient ────────────────────

    function test_wrongRecipient_reverts() public {
        address wrongRecipient = makeAddr("attacker");
        bytes memory data = _encodeSwap(
            WETH, USDC, FEE_3000, wrongRecipient, block.timestamp + 1, 1 ether, 0, 0
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapSwapPolicy.RecipientNotAccount.selector, wrongRecipient, account
            )
        );
        policy.checkAction(bytes32(0), account, target, 0, data);
    }

    // ──────────────────── Invalid Fee Tier ────────────────────

    function test_invalidFeeTier_reverts() public {
        bytes memory data = _encodeSwap(
            WETH, USDC, FEE_INVALID, account, block.timestamp + 1, 1 ether, 0, 0
        );
        vm.expectRevert(
            abi.encodeWithSelector(UniswapSwapPolicy.FeeTierNotAllowed.selector, FEE_INVALID)
        );
        policy.checkAction(bytes32(0), account, target, 0, data);
    }

    // ──────────────────── Daily Volume Limit ────────────────────

    function test_dailyVolumeExceeded_reverts() public {
        // First swap uses 9 ether of the 10 ether limit
        bytes memory data1 = _validSwapData(9 ether);
        policy.checkAction(bytes32(0), account, target, 0, data1);
        assertEq(policy.getDailyVolumeUsed(account), 9 ether);

        // Second swap of 2 ether should exceed the limit
        bytes memory data2 = _validSwapData(2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                UniswapSwapPolicy.DailyVolumeLimitExceeded.selector,
                11 ether,
                DAILY_LIMIT
            )
        );
        policy.checkAction(bytes32(0), account, target, 0, data2);
    }

    // ──────────────────── Daily Volume Resets ────────────────────

    function test_dailyVolumeResetsAfterOneDay() public {
        // Use up nearly all volume
        bytes memory data = _validSwapData(9 ether);
        policy.checkAction(bytes32(0), account, target, 0, data);
        assertEq(policy.getDailyVolumeUsed(account), 9 ether);

        // Warp to next day
        vm.warp(block.timestamp + 1 days);

        // Volume should be reset
        assertEq(policy.getDailyVolumeUsed(account), 0);

        // Should be able to swap full limit again
        bytes memory data2 = _validSwapData(10 ether);
        uint256 result = policy.checkAction(bytes32(0), account, target, 0, data2);
        assertEq(result, 0);
    }

    // ──────────────────── Edge: ETH value not allowed ────────────────────

    function test_ethValueNotAllowed_reverts() public {
        bytes memory data = _validSwapData(1 ether);
        vm.expectRevert(UniswapSwapPolicy.NoEthValueAllowed.selector);
        policy.checkAction(bytes32(0), account, target, 1 ether, data);
    }

    // ──────────────────── Security Fix: C-01 Access Control ────────────────────

    function test_initializePolicy_onlyAccount() public {
        UniswapSwapPolicy freshPolicy = new UniswapSwapPolicy();
        address attacker = makeAddr("attacker");

        address[] memory tokensIn = new address[](1);
        tokensIn[0] = WETH;
        address[] memory tokensOut = new address[](1);
        tokensOut[0] = USDC;
        uint24[] memory feeTiers = new uint24[](1);
        feeTiers[0] = FEE_3000;

        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            allowedTokensIn: tokensIn,
            allowedTokensOut: tokensOut,
            requiredRecipient: attacker,
            allowedFeeTiers: feeTiers,
            dailyVolumeLimit: type(uint256).max
        });

        // Attacker tries to initialize -- should fail
        vm.prank(attacker);
        vm.expectRevert(UniswapSwapPolicy.OnlyAccount.selector);
        freshPolicy.initializePolicy(account, config);
    }

    function test_initializePolicy_alreadyInitialized_reverts() public {
        // Policy was already initialized in setUp
        address[] memory tokensIn = new address[](1);
        tokensIn[0] = WETH;
        address[] memory tokensOut = new address[](1);
        tokensOut[0] = USDC;
        uint24[] memory feeTiers = new uint24[](1);
        feeTiers[0] = FEE_3000;

        UniswapSwapPolicy.SwapConfig memory config = UniswapSwapPolicy.SwapConfig({
            allowedTokensIn: tokensIn,
            allowedTokensOut: tokensOut,
            requiredRecipient: account,
            allowedFeeTiers: feeTiers,
            dailyVolumeLimit: DAILY_LIMIT
        });

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(UniswapSwapPolicy.AlreadyInitialized.selector, account));
        policy.initializePolicy(account, config);
    }
}
