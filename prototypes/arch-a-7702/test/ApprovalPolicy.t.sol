// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ApprovalPolicy} from "../src/policies/ApprovalPolicy.sol";

contract ApprovalPolicyTest is Test {
    ApprovalPolicy policy;

    address account = makeAddr("account");
    address target = makeAddr("token");

    address constant SPENDER_A = address(0xAAA);
    address constant SPENDER_B = address(0xBBB);
    address constant UNKNOWN_SPENDER = address(0xDDD);

    uint256 constant MAX_APPROVAL = 1_000_000e18;

    // ERC-20 approve(address,uint256) selector
    bytes4 constant APPROVE_SELECTOR = 0x095ea7b3;

    function setUp() public {
        policy = new ApprovalPolicy();

        address[] memory spenders = new address[](2);
        spenders[0] = SPENDER_A;
        spenders[1] = SPENDER_B;

        ApprovalPolicy.ApprovalConfig memory config = ApprovalPolicy.ApprovalConfig({
            allowedSpenders: spenders,
            maxApproval: MAX_APPROVAL
        });

        // [C-01] Must call initializePolicy as the account itself
        vm.prank(account);
        policy.initializePolicy(account, config);
    }

    function _encodeApprove(address spender, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(APPROVE_SELECTOR, spender, amount);
    }

    // ──────────────────── Valid Approval ────────────────────

    function test_validApproval() public {
        bytes memory data = _encodeApprove(SPENDER_A, 500_000e18);
        uint256 result = policy.checkAction(bytes32(0), account, target, 0, data);
        assertEq(result, 0);
    }

    // ──────────────────── Unknown Spender ────────────────────

    function test_unknownSpender_reverts() public {
        bytes memory data = _encodeApprove(UNKNOWN_SPENDER, 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(ApprovalPolicy.SpenderNotAllowed.selector, UNKNOWN_SPENDER)
        );
        policy.checkAction(bytes32(0), account, target, 0, data);
    }

    // ──────────────────── Excessive Approval ────────────────────

    function test_excessiveApproval_reverts() public {
        bytes memory data = _encodeApprove(SPENDER_A, MAX_APPROVAL + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ApprovalPolicy.ExceedsMaxApproval.selector, MAX_APPROVAL + 1, MAX_APPROVAL
            )
        );
        policy.checkAction(bytes32(0), account, target, 0, data);
    }

    // ──────────────────── ETH Value Not Allowed ────────────────────

    function test_ethValueNotAllowed_reverts() public {
        bytes memory data = _encodeApprove(SPENDER_A, 100e18);
        vm.expectRevert(ApprovalPolicy.NoEthValueAllowed.selector);
        policy.checkAction(bytes32(0), account, target, 1 ether, data);
    }

    // ──────────────────── Security Fix: C-01 Access Control ────────────────────

    function test_initializePolicy_onlyAccount() public {
        ApprovalPolicy freshPolicy = new ApprovalPolicy();
        address attacker = makeAddr("attacker");

        address[] memory spenders = new address[](1);
        spenders[0] = attacker;

        ApprovalPolicy.ApprovalConfig memory config = ApprovalPolicy.ApprovalConfig({
            allowedSpenders: spenders,
            maxApproval: type(uint256).max
        });

        vm.prank(attacker);
        vm.expectRevert(ApprovalPolicy.OnlyAccount.selector);
        freshPolicy.initializePolicy(account, config);
    }

    function test_initializePolicy_alreadyInitialized_reverts() public {
        address[] memory spenders = new address[](1);
        spenders[0] = SPENDER_A;

        ApprovalPolicy.ApprovalConfig memory config = ApprovalPolicy.ApprovalConfig({
            allowedSpenders: spenders,
            maxApproval: MAX_APPROVAL
        });

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(ApprovalPolicy.AlreadyInitialized.selector, account));
        policy.initializePolicy(account, config);
    }
}
