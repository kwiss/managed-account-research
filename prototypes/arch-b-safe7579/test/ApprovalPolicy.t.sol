// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ApprovalPolicy} from "../src/policies/ApprovalPolicy.sol";

contract ApprovalPolicyTest is Test {
    ApprovalPolicy public policy;

    address public account = address(0xACC);
    address public token = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    address public spender = address(0xDEF1); // DeFi protocol

    bytes4 public constant APPROVE_SELECTOR = bytes4(keccak256("approve(address,uint256)"));

    function setUp() public {
        policy = new ApprovalPolicy();
    }

    function _buildApproveCalldata(address _spender, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(APPROVE_SELECTOR, _spender, amount);
    }

    // ─── Valid Approval Tests ────────────────────────────────────────────────

    function test_checkAction_validApproval() public {
        ApprovalPolicy.ApprovalConfig memory config =
            ApprovalPolicy.ApprovalConfig({spender: spender, maxAmount: 1_000_000e6, active: true});

        vm.prank(account);
        policy.setApprovalConfig(token, config);

        bytes memory callData = _buildApproveCalldata(spender, 500_000e6);
        assertTrue(policy.checkAction(account, token, 0, callData));
    }

    function test_checkAction_validApproval_anySpender() public {
        ApprovalPolicy.ApprovalConfig memory config =
            ApprovalPolicy.ApprovalConfig({spender: address(0), maxAmount: 0, active: true});

        vm.prank(account);
        policy.setApprovalConfig(token, config);

        bytes memory callData = _buildApproveCalldata(address(0x123), type(uint256).max);
        assertTrue(policy.checkAction(account, token, 0, callData));
    }

    // ─── Invalid Approval Tests ──────────────────────────────────────────────

    function test_checkAction_revert_policyNotConfigured() public {
        bytes memory callData = _buildApproveCalldata(spender, 100e6);

        vm.expectRevert(abi.encodeWithSelector(ApprovalPolicy.PolicyNotConfigured.selector, account, token));
        policy.checkAction(account, token, 0, callData);
    }

    function test_checkAction_revert_invalidSpender() public {
        ApprovalPolicy.ApprovalConfig memory config =
            ApprovalPolicy.ApprovalConfig({spender: spender, maxAmount: 0, active: true});

        vm.prank(account);
        policy.setApprovalConfig(token, config);

        address wrongSpender = address(0xBAD);
        bytes memory callData = _buildApproveCalldata(wrongSpender, 100e6);

        vm.expectRevert(abi.encodeWithSelector(ApprovalPolicy.InvalidSpender.selector, wrongSpender, spender));
        policy.checkAction(account, token, 0, callData);
    }

    function test_checkAction_revert_amountExceedsLimit() public {
        ApprovalPolicy.ApprovalConfig memory config =
            ApprovalPolicy.ApprovalConfig({spender: spender, maxAmount: 1_000_000e6, active: true});

        vm.prank(account);
        policy.setApprovalConfig(token, config);

        bytes memory callData = _buildApproveCalldata(spender, 2_000_000e6);

        vm.expectRevert(
            abi.encodeWithSelector(ApprovalPolicy.AmountExceedsLimit.selector, 2_000_000e6, 1_000_000e6)
        );
        policy.checkAction(account, token, 0, callData);
    }

    function test_checkAction_revert_invalidCalldata() public {
        ApprovalPolicy.ApprovalConfig memory config =
            ApprovalPolicy.ApprovalConfig({spender: spender, maxAmount: 0, active: true});

        vm.prank(account);
        policy.setApprovalConfig(token, config);

        vm.expectRevert(ApprovalPolicy.InvalidCalldata.selector);
        policy.checkAction(account, token, 0, hex"deadbeef");
    }

    function test_checkAction_exactMaxAmount() public {
        ApprovalPolicy.ApprovalConfig memory config =
            ApprovalPolicy.ApprovalConfig({spender: spender, maxAmount: 1_000_000e6, active: true});

        vm.prank(account);
        policy.setApprovalConfig(token, config);

        bytes memory callData = _buildApproveCalldata(spender, 1_000_000e6);
        assertTrue(policy.checkAction(account, token, 0, callData));
    }
}
