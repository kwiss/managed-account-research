// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ManagedAccountTimelockHook} from "../src/hooks/ManagedAccountTimelockHook.sol";
import {IManagedAccountTimelockHook} from "../src/hooks/IManagedAccountTimelockHook.sol";
import {MODULE_TYPE_HOOK, MODULE_TYPE_VALIDATOR} from "../src/types/ModuleType.sol";

/// @dev Mock Safe that tracks owners
contract MockSafe {
    mapping(address => bool) public owners;

    function addOwner(address owner) external {
        owners[owner] = true;
    }

    function isOwner(address owner) external view returns (bool) {
        return owners[owner];
    }
}

contract ManagedAccountTimelockHookTest is Test {
    ManagedAccountTimelockHook public hook;
    MockSafe public mockSafe;

    // account IS the MockSafe — because safeAccount = msg.sender in onInstall
    address public account;
    address public owner = address(0x1);
    address public operator = address(0x2);
    address public target = address(0xDEF1);

    uint256 public constant COOLDOWN = 1 hours;
    uint256 public constant EXPIRATION = 24 hours;

    bytes4 public constant EXECUTE_SELECTOR = bytes4(keccak256("execute(bytes32,bytes)"));
    bytes4 public constant SWAP_SELECTOR = bytes4(keccak256("swap(address,uint256)"));

    function setUp() public {
        hook = new ManagedAccountTimelockHook();
        mockSafe = new MockSafe();
        mockSafe.addOwner(owner);

        // account IS the mockSafe address, since safeAccount = msg.sender in onInstall
        account = address(mockSafe);

        // H-02/M-05: onInstall now only takes (cooldown, expiration) and uses msg.sender as safeAccount
        bytes memory installData = abi.encode(COOLDOWN, EXPIRATION);
        vm.prank(account);
        hook.onInstall(installData);
    }

    // ─── Helper: build ERC-7579 execute calldata ─────────────────────────────

    function _buildExecuteCalldata(address _target, uint256 value, bytes memory callData)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 mode = bytes32(0);
        bytes memory executionCalldata = abi.encodePacked(_target, value, callData);
        return abi.encodeWithSelector(EXECUTE_SELECTOR, mode, executionCalldata);
    }

    function _computeOpHash(address _account, address _operator, bytes memory msgData)
        internal
        pure
        returns (bytes32)
    {
        // H-03: Use abi.encode instead of abi.encodePacked
        return keccak256(abi.encode(_account, _operator, msgData));
    }

    // ─── Test: Module Type ───────────────────────────────────────────────────

    function test_isModuleType_hook() public view {
        assertTrue(hook.isModuleType(MODULE_TYPE_HOOK));
    }

    function test_isModuleType_notValidator() public view {
        assertFalse(hook.isModuleType(MODULE_TYPE_VALIDATOR));
    }

    // ─── Test: onInstall / onUninstall ───────────────────────────────────────

    function test_onInstall_setsConfig() public view {
        IManagedAccountTimelockHook.TimelockConfig memory config = hook.getTimelockConfig(account);
        assertEq(config.cooldown, COOLDOWN);
        assertEq(config.expiration, EXPIRATION);
        // safeAccount is now msg.sender (the account itself)
        assertEq(config.safeAccount, account);
    }

    function test_onInstall_revert_cooldownTooShort() public {
        address newAccount = address(0xBBB);
        vm.prank(newAccount);
        vm.expectRevert(IManagedAccountTimelockHook.InvalidTimelockConfig.selector);
        // M-02: cooldown below MIN_COOLDOWN (5 minutes) should revert
        hook.onInstall(abi.encode(1 minutes, EXPIRATION));
    }

    function test_onInstall_revert_zeroExpiration() public {
        address newAccount = address(0xBBB);
        vm.prank(newAccount);
        vm.expectRevert(IManagedAccountTimelockHook.InvalidTimelockConfig.selector);
        hook.onInstall(abi.encode(COOLDOWN, 0));
    }

    function test_onUninstall_clearsConfig() public {
        vm.prank(account);
        hook.onUninstall("");

        IManagedAccountTimelockHook.TimelockConfig memory config = hook.getTimelockConfig(account);
        assertEq(config.cooldown, 0);
        assertEq(config.safeAccount, address(0));
        // Generation should be incremented
        assertEq(config.generation, 1);
    }

    // ─── Test: Owner Bypass ──────────────────────────────────────────────────

    function test_preCheck_ownerBypass() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));

        vm.prank(account);
        bytes memory hookData = hook.preCheck(owner, 0, msgData);

        assertEq(abi.decode(hookData, (bool)), false);
    }

    // ─── Test: Operator Queue + Execute ──────────────────────────────────────

    function test_queueOperation() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));
        bytes32 opHash = _computeOpHash(account, operator, msgData);

        // C-01: Must prank as operator or account to queue
        vm.prank(operator);
        hook.queueOperation(account, operator, msgData);

        IManagedAccountTimelockHook.QueuedOperation memory op = hook.getQueuedOperation(account, opHash);
        assertEq(op.queuedAt, block.timestamp);
        assertFalse(op.consumed);
    }

    function test_queueOperation_asAccount() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));
        bytes32 opHash = _computeOpHash(account, operator, msgData);

        // C-01: Account itself can also queue
        vm.prank(account);
        hook.queueOperation(account, operator, msgData);

        IManagedAccountTimelockHook.QueuedOperation memory op = hook.getQueuedOperation(account, opHash);
        assertEq(op.queuedAt, block.timestamp);
        assertFalse(op.consumed);
    }

    function test_queueOperation_revert_unauthorized() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));

        // C-01: Random address cannot queue
        address randomCaller = address(0xBAD);
        vm.prank(randomCaller);
        vm.expectRevert(IManagedAccountTimelockHook.UnauthorizedCaller.selector);
        hook.queueOperation(account, operator, msgData);
    }

    function test_queueOperation_revert_alreadyQueued() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));
        bytes32 opHash = _computeOpHash(account, operator, msgData);

        vm.prank(operator);
        hook.queueOperation(account, operator, msgData);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IManagedAccountTimelockHook.OperationAlreadyQueued.selector, opHash));
        hook.queueOperation(account, operator, msgData);
    }

    function test_preCheck_operatorExecutesAfterCooldown() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));
        bytes32 opHash = _computeOpHash(account, operator, msgData);

        // Queue (as operator)
        vm.prank(operator);
        hook.queueOperation(account, operator, msgData);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Execute
        vm.prank(account);
        bytes memory hookData = hook.preCheck(operator, 0, msgData);
        assertEq(abi.decode(hookData, (bool)), true);

        // Verify consumed
        IManagedAccountTimelockHook.QueuedOperation memory op = hook.getQueuedOperation(account, opHash);
        assertTrue(op.consumed);
    }

    function test_preCheck_operatorRejectedNotQueued() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));
        bytes32 opHash = _computeOpHash(account, operator, msgData);

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IManagedAccountTimelockHook.OperationNotFound.selector, opHash));
        hook.preCheck(operator, 0, msgData);
    }

    function test_preCheck_operatorRejectedDuringCooldown() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));
        bytes32 opHash = _computeOpHash(account, operator, msgData);

        uint256 queueTime = block.timestamp;
        vm.prank(operator);
        hook.queueOperation(account, operator, msgData);

        // Still in cooldown
        vm.warp(queueTime + COOLDOWN - 1);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(IManagedAccountTimelockHook.OperationNotReady.selector, opHash, queueTime + COOLDOWN)
        );
        hook.preCheck(operator, 0, msgData);
    }

    // ─── Test: Expired Operation ─────────────────────────────────────────────

    function test_preCheck_expiredOperation() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));
        bytes32 opHash = _computeOpHash(account, operator, msgData);

        uint256 queueTime = block.timestamp;
        vm.prank(operator);
        hook.queueOperation(account, operator, msgData);

        // Warp past cooldown + expiration
        vm.warp(queueTime + COOLDOWN + EXPIRATION + 1);

        vm.prank(account);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedAccountTimelockHook.OperationExpired.selector, opHash, queueTime + COOLDOWN + EXPIRATION
            )
        );
        hook.preCheck(operator, 0, msgData);
    }

    // ─── Test: Owner Cancel ──────────────────────────────────────────────────

    function test_cancelExecution_ownerCancels() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));
        bytes32 opHash = _computeOpHash(account, operator, msgData);

        vm.prank(operator);
        hook.queueOperation(account, operator, msgData);

        // C-02: Cancel requires msgSender who is an owner
        vm.prank(account);
        hook.cancelExecution(owner, opHash);

        // Verify consumed
        IManagedAccountTimelockHook.QueuedOperation memory op = hook.getQueuedOperation(account, opHash);
        assertTrue(op.consumed);

        // Trying to execute after cooldown should fail (consumed)
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IManagedAccountTimelockHook.OperationNotFound.selector, opHash));
        hook.preCheck(operator, 0, msgData);
    }

    function test_cancelExecution_revert_notOwner() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));
        bytes32 opHash = _computeOpHash(account, operator, msgData);

        vm.prank(operator);
        hook.queueOperation(account, operator, msgData);

        // C-02: Non-owner cannot cancel
        vm.prank(account);
        vm.expectRevert(IManagedAccountTimelockHook.OnlyOwner.selector);
        hook.cancelExecution(operator, opHash); // operator is not an owner
    }

    function test_cancelExecution_revert_notFound() public {
        bytes32 fakeHash = keccak256("fake");

        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IManagedAccountTimelockHook.OperationNotFound.selector, fakeHash));
        hook.cancelExecution(owner, fakeHash);
    }

    // ─── Test: Immediate Selector Bypass ─────────────────────────────────────

    function test_preCheck_immediateSelectorBypass() public {
        vm.prank(account);
        hook.setImmediateSelector(target, SWAP_SELECTOR, true);

        assertTrue(hook.isImmediateSelector(account, target, SWAP_SELECTOR));

        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));

        vm.prank(account);
        bytes memory hookData = hook.preCheck(operator, 0, msgData);
        assertEq(abi.decode(hookData, (bool)), false);
    }

    function test_setImmediateSelector_disable() public {
        vm.prank(account);
        hook.setImmediateSelector(target, SWAP_SELECTOR, true);

        vm.prank(account);
        hook.setImmediateSelector(target, SWAP_SELECTOR, false);

        assertFalse(hook.isImmediateSelector(account, target, SWAP_SELECTOR));
    }

    // ─── Test: Configure Timelock ────────────────────────────────────────────

    function test_setTimelockConfig() public {
        uint256 newCooldown = 2 hours;
        uint256 newExpiration = 48 hours;

        vm.prank(account);
        hook.setTimelockConfig(newCooldown, newExpiration);

        IManagedAccountTimelockHook.TimelockConfig memory config = hook.getTimelockConfig(account);
        assertEq(config.cooldown, newCooldown);
        assertEq(config.expiration, newExpiration);
    }

    function test_setTimelockConfig_revert_cooldownTooShort() public {
        vm.prank(account);
        // M-02: Cooldown below MIN_COOLDOWN (5 min) should revert
        vm.expectRevert(IManagedAccountTimelockHook.CooldownTooShort.selector);
        hook.setTimelockConfig(1 minutes, EXPIRATION);
    }

    function test_setTimelockConfig_revert_notInitialized() public {
        vm.prank(address(0xFFF));
        vm.expectRevert(IManagedAccountTimelockHook.NotInitialized.selector);
        hook.setTimelockConfig(COOLDOWN, EXPIRATION);
    }

    // ─── Test: Not Initialized ───────────────────────────────────────────────

    function test_preCheck_revert_notInitialized() public {
        address uninitAccount = address(0xFFF);
        bytes memory msgData = _buildExecuteCalldata(target, 0, "");

        vm.prank(uninitAccount);
        vm.expectRevert(IManagedAccountTimelockHook.NotInitialized.selector);
        hook.preCheck(operator, 0, msgData);
    }

    function test_queueOperation_revert_notInitialized() public {
        address uninitAccount = address(0xFFF);
        bytes memory msgData = _buildExecuteCalldata(target, 0, "");

        // Must prank as operator since we pass operator as the operator param
        vm.prank(operator);
        vm.expectRevert(IManagedAccountTimelockHook.NotInitialized.selector);
        hook.queueOperation(uninitAccount, operator, msgData);
    }

    // ─── Test: H-06 Batch execution mode rejected ────────────────────────────

    function test_preCheck_revert_batchExecutionMode() public {
        // Build calldata with non-zero mode (batch mode)
        bytes32 batchMode = bytes32(uint256(1));
        bytes memory executionCalldata = abi.encodePacked(target, uint256(0), abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));
        bytes memory msgData = abi.encodeWithSelector(EXECUTE_SELECTOR, batchMode, executionCalldata);

        vm.prank(account);
        vm.expectRevert(IManagedAccountTimelockHook.UnsupportedExecutionMode.selector);
        hook.preCheck(operator, 0, msgData);
    }

    // ─── Test: M-06 Generation nonce invalidation ────────────────────────────

    function test_uninstall_invalidatesOldQueue() public {
        bytes memory msgData = _buildExecuteCalldata(target, 0, abi.encodeWithSelector(SWAP_SELECTOR, address(0), 100));
        bytes32 opHash = _computeOpHash(account, operator, msgData);

        // Queue an operation
        vm.prank(operator);
        hook.queueOperation(account, operator, msgData);

        // Uninstall
        vm.prank(account);
        hook.onUninstall("");

        // Reinstall
        vm.prank(account);
        hook.onInstall(abi.encode(COOLDOWN, EXPIRATION));

        // The old queued operation should not be valid after reinstall
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(IManagedAccountTimelockHook.OperationNotFound.selector, opHash));
        hook.preCheck(operator, 0, msgData);
    }
}
