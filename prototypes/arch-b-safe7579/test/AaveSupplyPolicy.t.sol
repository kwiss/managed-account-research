// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {AaveSupplyPolicy} from "../src/policies/AaveSupplyPolicy.sol";

contract AaveSupplyPolicyTest is Test {
    AaveSupplyPolicy public policy;

    address public account = address(0xACC);
    address public aavePool = address(0xAA7E);
    address public usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    bytes4 public constant SUPPLY_SELECTOR = bytes4(keccak256("supply(address,uint256,address,uint16)"));

    function setUp() public {
        policy = new AaveSupplyPolicy();
    }

    function _buildSupplyCalldata(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(SUPPLY_SELECTOR, asset, amount, onBehalfOf, referralCode);
    }

    // ─── Valid Supply Tests ──────────────────────────────────────────────────

    function test_checkAction_validSupply() public {
        AaveSupplyPolicy.SupplyConfig memory config = AaveSupplyPolicy.SupplyConfig({
            asset: usdc,
            onBehalfOf: account,
            maxDailyVolume: 1_000_000e6, // 1M USDC
            active: true
        });

        vm.prank(account);
        policy.setSupplyConfig(aavePool, config);

        bytes memory callData = _buildSupplyCalldata(usdc, 100_000e6, account, 0);
        vm.prank(account);
        assertTrue(policy.checkAction(account, aavePool, 0, callData));
    }

    function test_checkAction_validSupply_anyAsset() public {
        AaveSupplyPolicy.SupplyConfig memory config = AaveSupplyPolicy.SupplyConfig({
            asset: address(0), // any
            onBehalfOf: account,
            maxDailyVolume: 0, // unlimited
            active: true
        });

        vm.prank(account);
        policy.setSupplyConfig(aavePool, config);

        bytes memory callData = _buildSupplyCalldata(usdc, 500_000e6, account, 0);
        vm.prank(account);
        assertTrue(policy.checkAction(account, aavePool, 0, callData));
    }

    // ─── Invalid Supply Tests ────────────────────────────────────────────────

    function test_checkAction_revert_policyNotConfigured() public {
        bytes memory callData = _buildSupplyCalldata(usdc, 100e6, account, 0);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(AaveSupplyPolicy.PolicyNotConfigured.selector, account, aavePool)
        );
        policy.checkAction(account, aavePool, 0, callData);
    }

    function test_checkAction_revert_invalidAsset() public {
        AaveSupplyPolicy.SupplyConfig memory config = AaveSupplyPolicy.SupplyConfig({
            asset: usdc,
            onBehalfOf: account,
            maxDailyVolume: 0,
            active: true
        });

        vm.prank(account);
        policy.setSupplyConfig(aavePool, config);

        address wrongAsset = address(0xBAD);
        bytes memory callData = _buildSupplyCalldata(wrongAsset, 100e6, account, 0);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(AaveSupplyPolicy.InvalidAsset.selector, wrongAsset, usdc));
        policy.checkAction(account, aavePool, 0, callData);
    }

    function test_checkAction_revert_invalidOnBehalfOf() public {
        AaveSupplyPolicy.SupplyConfig memory config = AaveSupplyPolicy.SupplyConfig({
            asset: usdc,
            onBehalfOf: account,
            maxDailyVolume: 0,
            active: true
        });

        vm.prank(account);
        policy.setSupplyConfig(aavePool, config);

        address wrongRecipient = address(0xBAD);
        bytes memory callData = _buildSupplyCalldata(usdc, 100e6, wrongRecipient, 0);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(AaveSupplyPolicy.InvalidOnBehalfOf.selector, wrongRecipient, account)
        );
        policy.checkAction(account, aavePool, 0, callData);
    }

    function test_checkAction_revert_dailyVolumeExceeded() public {
        AaveSupplyPolicy.SupplyConfig memory config = AaveSupplyPolicy.SupplyConfig({
            asset: usdc,
            onBehalfOf: account,
            maxDailyVolume: 500_000e6, // 500K USDC
            active: true
        });

        vm.prank(account);
        policy.setSupplyConfig(aavePool, config);

        // First supply OK
        bytes memory callData = _buildSupplyCalldata(usdc, 400_000e6, account, 0);
        vm.prank(account);
        policy.checkAction(account, aavePool, 0, callData);

        // Second supply exceeds
        bytes memory callData2 = _buildSupplyCalldata(usdc, 200_000e6, account, 0);
        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(AaveSupplyPolicy.DailyVolumeLimitExceeded.selector, 600_000e6, 500_000e6)
        );
        policy.checkAction(account, aavePool, 0, callData2);
    }

    function test_checkAction_dailyVolumeResets() public {
        AaveSupplyPolicy.SupplyConfig memory config = AaveSupplyPolicy.SupplyConfig({
            asset: usdc,
            onBehalfOf: account,
            maxDailyVolume: 500_000e6,
            active: true
        });

        vm.prank(account);
        policy.setSupplyConfig(aavePool, config);

        bytes memory callData = _buildSupplyCalldata(usdc, 400_000e6, account, 0);
        vm.prank(account);
        policy.checkAction(account, aavePool, 0, callData);

        vm.warp(block.timestamp + 1 days);

        // Should be allowed again
        vm.prank(account);
        assertTrue(policy.checkAction(account, aavePool, 0, callData));
    }

    function test_checkAction_revert_invalidCalldata() public {
        AaveSupplyPolicy.SupplyConfig memory config = AaveSupplyPolicy.SupplyConfig({
            asset: usdc,
            onBehalfOf: account,
            maxDailyVolume: 0,
            active: true
        });

        vm.prank(account);
        policy.setSupplyConfig(aavePool, config);

        vm.prank(account);
        vm.expectRevert(AaveSupplyPolicy.InvalidCalldata.selector);
        policy.checkAction(account, aavePool, 0, hex"deadbeef");
    }

    // ─── Test: H-01 unauthorized caller ──────────────────────────────────────

    function test_checkAction_revert_unauthorizedCaller() public {
        AaveSupplyPolicy.SupplyConfig memory config = AaveSupplyPolicy.SupplyConfig({
            asset: usdc,
            onBehalfOf: account,
            maxDailyVolume: 500_000e6,
            active: true
        });

        vm.prank(account);
        policy.setSupplyConfig(aavePool, config);

        bytes memory callData = _buildSupplyCalldata(usdc, 100_000e6, account, 0);

        // Random caller should be rejected
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(AaveSupplyPolicy.UnauthorizedCaller.selector);
        policy.checkAction(account, aavePool, 0, callData);
    }
}
