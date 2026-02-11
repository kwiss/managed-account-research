// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ManagedAccountTimelockHook} from "../src/hooks/ManagedAccountTimelockHook.sol";
import {IManagedAccountTimelockHook} from "../src/hooks/IManagedAccountTimelockHook.sol";

/// @dev Mock account that calls the hook's functions, simulating ERC-7579 account context.
contract MockAccount {
    ManagedAccountTimelockHook public hook;

    constructor(ManagedAccountTimelockHook _hook) {
        hook = _hook;
    }

    function install(bytes calldata data) external {
        hook.onInstall(data);
    }

    function uninstall() external {
        hook.onUninstall("");
    }

    function callPreCheck(address msgSender, uint256 msgValue, bytes calldata msgData)
        external
        returns (bytes memory)
    {
        return hook.preCheck(msgSender, msgValue, msgData);
    }

    function callPostCheck(bytes calldata hookData) external {
        hook.postCheck(hookData);
    }

    function cancel(bytes32 execHash) external {
        hook.cancelExecution(execHash);
    }

    function configure(uint128 cooldown, uint128 expiration) external {
        hook.setTimelockConfig(cooldown, expiration);
    }

    function whitelist(address target, bytes4 selector, bool immediate) external {
        hook.setImmediateSelector(target, selector, immediate);
    }

    function queueAsAccount(address operator, uint256 msgValue, bytes calldata msgData) external {
        hook.queueOperation(address(this), operator, msgValue, msgData);
    }
}

contract ManagedAccountTimelockHookTest is Test {
    ManagedAccountTimelockHook hook;
    MockAccount account;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");

    uint128 constant COOLDOWN = 1 hours;
    uint128 constant EXPIRATION = 24 hours;

    bytes constant SAMPLE_DATA = hex"aabbccdd11223344";

    function setUp() public {
        hook = new ManagedAccountTimelockHook();
        account = new MockAccount(hook);
        account.install(abi.encode(owner, COOLDOWN, EXPIRATION));
    }

    // ──────────────────── Owner Bypass ────────────────────

    function test_ownerBypass() public {
        bytes memory hookData = account.callPreCheck(owner, 0, SAMPLE_DATA);
        (bool isOwner, bytes32 execHash) = abi.decode(hookData, (bool, bytes32));
        assertTrue(isOwner);
        assertEq(execHash, bytes32(0));
    }

    // ──────────────────── Operator Queue ────────────────────

    function test_operatorQueue() public {
        bytes32 expectedHash = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);

        // [C-02] Queue the operation as the operator (authorized caller)
        vm.prank(operator);
        hook.queueOperation(address(account), operator, 0, SAMPLE_DATA);

        // Verify queue entry exists
        IManagedAccountTimelockHook.QueueEntry memory entry =
            hook.getQueueEntry(address(account), expectedHash);
        assertTrue(entry.exists);
        assertEq(entry.operator, operator);
        assertEq(entry.executeAfter, uint48(block.timestamp + COOLDOWN));
        assertEq(entry.expiresAt, uint48(block.timestamp + COOLDOWN + EXPIRATION));
    }

    function test_operatorPreCheck_notQueued_reverts() public {
        bytes32 expectedHash = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);

        // preCheck without queuing first should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedAccountTimelockHook.OperationNotQueued.selector,
                expectedHash
            )
        );
        account.callPreCheck(operator, 0, SAMPLE_DATA);
    }

    // ──────────────────── Operator Execute After Cooldown ────────────────────

    function test_operatorExecuteAfterCooldown() public {
        bytes32 expectedHash = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);

        // [C-02] Queue the operation as the operator
        vm.prank(operator);
        hook.queueOperation(address(account), operator, 0, SAMPLE_DATA);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        // preCheck should succeed
        bytes memory hookData = account.callPreCheck(operator, 0, SAMPLE_DATA);
        (bool isOwner, bytes32 returnedHash) = abi.decode(hookData, (bool, bytes32));
        assertFalse(isOwner);
        assertEq(returnedHash, expectedHash);

        // [H-06] Queue entry should NOT be cleared yet (moved to postCheck)
        IManagedAccountTimelockHook.QueueEntry memory entry =
            hook.getQueueEntry(address(account), expectedHash);
        assertTrue(entry.exists);

        // Call postCheck to finalize and clear the queue entry
        account.callPostCheck(hookData);

        // Now queue entry should be cleared
        entry = hook.getQueueEntry(address(account), expectedHash);
        assertFalse(entry.exists);
    }

    // ──────────────────── Cooldown Not Elapsed ────────────────────

    function test_operatorCooldownNotElapsed_reverts() public {
        bytes32 expectedHash = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);

        // [C-02] Queue as operator
        vm.prank(operator);
        hook.queueOperation(address(account), operator, 0, SAMPLE_DATA);

        // Don't warp -- cooldown hasn't elapsed
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedAccountTimelockHook.CooldownNotElapsed.selector,
                expectedHash,
                uint48(block.timestamp + COOLDOWN)
            )
        );
        account.callPreCheck(operator, 0, SAMPLE_DATA);
    }

    // ──────────────────── Operator Expired Operation ────────────────────

    function test_operatorExpiredOperation() public {
        bytes32 expectedHash = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);
        uint48 expiresAt = uint48(block.timestamp + COOLDOWN + EXPIRATION);

        // [C-02] Queue as operator
        vm.prank(operator);
        hook.queueOperation(address(account), operator, 0, SAMPLE_DATA);

        // Warp past expiration
        vm.warp(block.timestamp + COOLDOWN + EXPIRATION + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedAccountTimelockHook.OperationExpired.selector,
                expectedHash,
                expiresAt
            )
        );
        account.callPreCheck(operator, 0, SAMPLE_DATA);
    }

    // ──────────────────── Owner Cancel ────────────────────

    function test_ownerCancel() public {
        bytes32 expectedHash = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);

        // [C-02] Queue the operation as operator
        vm.prank(operator);
        hook.queueOperation(address(account), operator, 0, SAMPLE_DATA);

        // Verify it's queued
        IManagedAccountTimelockHook.QueueEntry memory entry =
            hook.getQueueEntry(address(account), expectedHash);
        assertTrue(entry.exists);

        // Owner cancels (via account contract)
        account.cancel(expectedHash);

        // Verify it's cleared
        entry = hook.getQueueEntry(address(account), expectedHash);
        assertFalse(entry.exists);

        // Warp past cooldown -- operator tries to execute, but it was cancelled
        vm.warp(block.timestamp + COOLDOWN + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedAccountTimelockHook.OperationNotQueued.selector,
                expectedHash
            )
        );
        account.callPreCheck(operator, 0, SAMPLE_DATA);
    }

    // ──────────────────── Immediate Selector Bypass ────────────────────

    function test_immediateSelectorBypass() public {
        // [C-03] Immediate selector is now target-aware.
        // We need to construct msgData in ERC-7579 execute() format:
        //   [4-byte execute selector][32-byte mode][20-byte target][32-byte value][inner calldata]
        // mode = 0x00... (CALLTYPE_SINGLE)
        // target = some address
        // inner calldata starts with selector 0xaabbccdd

        bytes4 innerSelector = bytes4(hex"aabbccdd");
        address target = makeAddr("targetContract");

        // Whitelist the target+selector pair (not address(0))
        account.whitelist(target, innerSelector, true);

        assertTrue(hook.isImmediateSelector(address(account), target, innerSelector));

        // Construct ERC-7579 single execute calldata:
        // [4-byte execute selector][32-byte mode][20-byte target (packed)][32-byte value][inner calldata]
        bytes memory innerCalldata = abi.encodeWithSelector(innerSelector, uint256(42));
        bytes32 mode = bytes32(0); // CALLTYPE_SINGLE
        bytes memory msgData = abi.encodePacked(
            bytes4(0x12345678), // execute selector (arbitrary, we only care about layout after it)
            mode,               // 32-byte mode
            target,             // 20-byte target (packed)
            uint256(0),         // 32-byte value
            innerCalldata       // inner calldata starting with innerSelector
        );

        // Operator calls preCheck with matching ERC-7579 layout -- should pass immediately
        bytes memory hookData = account.callPreCheck(operator, 0, msgData);
        (bool isOwnerOrImmediate, bytes32 execHash) = abi.decode(hookData, (bool, bytes32));
        assertTrue(isOwnerOrImmediate);
        assertEq(execHash, bytes32(0));
    }

    function test_immediateSelectorBypass_wrongTarget_fallsThrough() public {
        // [C-03] Whitelist selector for a specific target
        bytes4 innerSelector = bytes4(hex"aabbccdd");
        address allowedTarget = makeAddr("allowedTarget");
        address wrongTarget = makeAddr("wrongTarget");

        account.whitelist(allowedTarget, innerSelector, true);

        // Construct ERC-7579 execute calldata with wrong target
        bytes memory innerCalldata = abi.encodeWithSelector(innerSelector, uint256(42));
        bytes32 mode = bytes32(0); // CALLTYPE_SINGLE
        bytes memory msgData = abi.encodePacked(
            bytes4(0x12345678),
            mode,
            wrongTarget,    // wrong target
            uint256(0),
            innerCalldata
        );

        // Should NOT match immediate selector and fall through to operator path
        bytes32 execHash = hook.computeExecHash(address(account), operator, 0, msgData);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedAccountTimelockHook.OperationNotQueued.selector,
                execHash
            )
        );
        account.callPreCheck(operator, 0, msgData);
    }

    // ──────────────────── Configure Timelock ────────────────────

    function test_configureTimelock() public {
        uint128 newCooldown = 2 hours;
        uint128 newExpiration = 48 hours;

        account.configure(newCooldown, newExpiration);

        IManagedAccountTimelockHook.TimelockConfig memory config =
            hook.getTimelockConfig(address(account));
        assertEq(config.cooldownPeriod, newCooldown);
        assertEq(config.expirationPeriod, newExpiration);
    }

    // ──────────────────── Edge Cases ────────────────────

    function test_cancelNonExistent_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedAccountTimelockHook.OperationNotQueued.selector,
                bytes32(uint256(123))
            )
        );
        account.cancel(bytes32(uint256(123)));
    }

    function test_configureZeroCooldown_reverts() public {
        vm.expectRevert(IManagedAccountTimelockHook.InvalidConfig.selector);
        account.configure(0, EXPIRATION);
    }

    function test_configureZeroExpiration_reverts() public {
        vm.expectRevert(IManagedAccountTimelockHook.InvalidConfig.selector);
        account.configure(COOLDOWN, 0);
    }

    function test_onlyAccountCanCancel() public {
        // Direct call from EOA (not an initialized account) should revert
        vm.prank(owner);
        vm.expectRevert(IManagedAccountTimelockHook.OnlyAccount.selector);
        hook.cancelExecution(bytes32(0));
    }

    function test_onlyAccountCanConfigure() public {
        vm.prank(owner);
        vm.expectRevert(IManagedAccountTimelockHook.OnlyAccount.selector);
        hook.setTimelockConfig(1 hours, 24 hours);
    }

    function test_isModuleType() public view {
        assertTrue(hook.isModuleType(4)); // MODULE_TYPE_HOOK
        assertFalse(hook.isModuleType(1)); // Not validator
    }

    function test_doubleQueue_reverts() public {
        bytes32 expectedHash = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);

        // [C-02] Queue as operator
        vm.prank(operator);
        hook.queueOperation(address(account), operator, 0, SAMPLE_DATA);

        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedAccountTimelockHook.AlreadyQueued.selector,
                expectedHash
            )
        );
        vm.prank(operator);
        hook.queueOperation(address(account), operator, 0, SAMPLE_DATA);
    }

    function test_queueForUninitializedAccount_reverts() public {
        address randomAccount = makeAddr("random");
        vm.expectRevert(IManagedAccountTimelockHook.NotInitialized.selector);
        vm.prank(operator);
        hook.queueOperation(randomAccount, operator, 0, SAMPLE_DATA);
    }

    // ──────────────────── Security Fix: C-02 Unauthorized Queue ────────────────────

    function test_queueUnauthorized_reverts() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(IManagedAccountTimelockHook.Unauthorized.selector);
        hook.queueOperation(address(account), operator, 0, SAMPLE_DATA);
    }

    function test_queueAsAccount_succeeds() public {
        // Account itself can queue on behalf of an operator
        account.queueAsAccount(operator, 0, SAMPLE_DATA);

        bytes32 expectedHash = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);
        IManagedAccountTimelockHook.QueueEntry memory entry =
            hook.getQueueEntry(address(account), expectedHash);
        assertTrue(entry.exists);
    }

    // ──────────────────── Security Fix: H-01 Re-install Guard ────────────────────

    function test_onInstall_revertIfAlreadyInstalled() public {
        // Account is already installed in setUp. Trying again should revert.
        vm.expectRevert(IManagedAccountTimelockHook.AlreadyInstalled.selector);
        account.install(abi.encode(owner, COOLDOWN, EXPIRATION));
    }

    function test_onInstall_revertIfZeroOwner() public {
        // Deploy a fresh hook and account
        ManagedAccountTimelockHook freshHook = new ManagedAccountTimelockHook();
        MockAccount freshAccount = new MockAccount(freshHook);

        vm.expectRevert(IManagedAccountTimelockHook.InvalidOwner.selector);
        freshAccount.install(abi.encode(address(0), COOLDOWN, EXPIRATION));
    }

    function test_onInstall_revertIfZeroCooldown() public {
        ManagedAccountTimelockHook freshHook = new ManagedAccountTimelockHook();
        MockAccount freshAccount = new MockAccount(freshHook);

        vm.expectRevert(IManagedAccountTimelockHook.InvalidConfig.selector);
        freshAccount.install(abi.encode(owner, uint128(0), EXPIRATION));
    }

    function test_onInstall_revertIfZeroExpiration() public {
        ManagedAccountTimelockHook freshHook = new ManagedAccountTimelockHook();
        MockAccount freshAccount = new MockAccount(freshHook);

        vm.expectRevert(IManagedAccountTimelockHook.InvalidConfig.selector);
        freshAccount.install(abi.encode(owner, COOLDOWN, uint128(0)));
    }

    // ──────────────────── Security Fix: H-02 Stale State After Reinstall ────────────────────

    function test_staleQueueInvalidatedAfterReinstall() public {
        // Queue an operation
        vm.prank(operator);
        hook.queueOperation(address(account), operator, 0, SAMPLE_DATA);

        bytes32 hashBeforeReinstall = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);
        IManagedAccountTimelockHook.QueueEntry memory entry =
            hook.getQueueEntry(address(account), hashBeforeReinstall);
        assertTrue(entry.exists);

        // Uninstall and reinstall
        account.uninstall();
        account.install(abi.encode(owner, COOLDOWN, EXPIRATION));

        // The exec hash changes because generation counter incremented
        bytes32 hashAfterReinstall = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);
        assertTrue(hashBeforeReinstall != hashAfterReinstall);

        // Old queue entry still exists in storage, but the new hash won't find it
        entry = hook.getQueueEntry(address(account), hashAfterReinstall);
        assertFalse(entry.exists);
    }

    // ──────────────────── Security Fix: H-04 Chain ID in Hash ────────────────────

    function test_execHashIncludesChainId() public {
        bytes32 hash1 = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);

        // Change chain id
        vm.chainId(999);
        bytes32 hash2 = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);

        assertTrue(hash1 != hash2);
    }

    // ──────────────────── Security Fix: H-05 Uninitialized preCheck ────────────────────

    function test_preCheckRevertsForUninitializedAccount() public {
        ManagedAccountTimelockHook freshHook = new ManagedAccountTimelockHook();
        MockAccount freshAccount = new MockAccount(freshHook);

        // preCheck on uninitialized account should revert
        vm.expectRevert(IManagedAccountTimelockHook.NotInitialized.selector);
        freshAccount.callPreCheck(operator, 0, SAMPLE_DATA);
    }

    // ──────────────────── Security Fix: H-06 Queue Deletion in postCheck ────────────────────

    function test_queueEntryDeletedInPostCheck() public {
        bytes32 expectedHash = hook.computeExecHash(address(account), operator, 0, SAMPLE_DATA);

        vm.prank(operator);
        hook.queueOperation(address(account), operator, 0, SAMPLE_DATA);

        vm.warp(block.timestamp + COOLDOWN + 1);

        // preCheck succeeds
        bytes memory hookData = account.callPreCheck(operator, 0, SAMPLE_DATA);

        // Queue entry still exists after preCheck
        IManagedAccountTimelockHook.QueueEntry memory entry =
            hook.getQueueEntry(address(account), expectedHash);
        assertTrue(entry.exists);

        // postCheck clears it
        account.callPostCheck(hookData);

        entry = hook.getQueueEntry(address(account), expectedHash);
        assertFalse(entry.exists);
    }

    // ──────────────────── Security Fix: M-04 Uint48 Bounds ────────────────────

    function test_configureExceedsUint48Bounds_reverts() public {
        uint128 tooLarge = uint128(type(uint48).max) + 1;

        vm.expectRevert(IManagedAccountTimelockHook.ConfigExceedsUint48Bounds.selector);
        account.configure(tooLarge, EXPIRATION);

        vm.expectRevert(IManagedAccountTimelockHook.ConfigExceedsUint48Bounds.selector);
        account.configure(COOLDOWN, tooLarge);
    }

    function test_onInstallExceedsUint48Bounds_reverts() public {
        ManagedAccountTimelockHook freshHook = new ManagedAccountTimelockHook();
        MockAccount freshAccount = new MockAccount(freshHook);
        uint128 tooLarge = uint128(type(uint48).max) + 1;

        vm.expectRevert(IManagedAccountTimelockHook.ConfigExceedsUint48Bounds.selector);
        freshAccount.install(abi.encode(owner, tooLarge, EXPIRATION));
    }

    // ──────────────────── Security Fix: M-05 Operator Mismatch ────────────────────

    function test_preCheckRevertsIfWrongOperator() public {
        address wrongOperator = makeAddr("wrongOperator");

        // Queue as operator
        vm.prank(operator);
        hook.queueOperation(address(account), operator, 0, SAMPLE_DATA);

        vm.warp(block.timestamp + COOLDOWN + 1);

        // Compute the hash that wrongOperator would generate -- it differs, so OperationNotQueued
        bytes32 wrongHash = hook.computeExecHash(address(account), wrongOperator, 0, SAMPLE_DATA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedAccountTimelockHook.OperationNotQueued.selector,
                wrongHash
            )
        );
        account.callPreCheck(wrongOperator, 0, SAMPLE_DATA);
    }
}
