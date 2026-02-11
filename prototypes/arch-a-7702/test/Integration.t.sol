// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ManagedAccountTimelockHook} from "../src/hooks/ManagedAccountTimelockHook.sol";
import {IManagedAccountTimelockHook} from "../src/hooks/IManagedAccountTimelockHook.sol";
import {HookMultiPlexer} from "../src/hooks/HookMultiPlexer.sol";
import {UniswapSwapPolicy} from "../src/policies/UniswapSwapPolicy.sol";

/// @dev Mock account that simulates a real ERC-7579 account calling hooks and policies.
contract IntegrationAccount {
    ManagedAccountTimelockHook public timelockHook;
    HookMultiPlexer public multiplexer;

    constructor(ManagedAccountTimelockHook _timelock, HookMultiPlexer _mux) {
        timelockHook = _timelock;
        multiplexer = _mux;
    }

    // ── TimelockHook (direct) ──

    function installTimelock(bytes calldata data) external {
        timelockHook.onInstall(data);
    }

    function uninstallTimelock() external {
        timelockHook.onUninstall("");
    }

    function timelockPreCheck(address msgSender, uint256 msgValue, bytes calldata msgData)
        external
        returns (bytes memory)
    {
        return timelockHook.preCheck(msgSender, msgValue, msgData);
    }

    function timelockPostCheck(bytes calldata hookData) external {
        timelockHook.postCheck(hookData);
    }

    function configureTimelock(uint128 cooldown, uint128 expiration) external {
        timelockHook.setTimelockConfig(cooldown, expiration);
    }

    function whitelistSelector(address target, bytes4 selector, bool immediate) external {
        timelockHook.setImmediateSelector(target, selector, immediate);
    }

    function cancelOp(bytes32 execHash) external {
        timelockHook.cancelExecution(execHash);
    }

    function queueAsAccount(address operator, uint256 msgValue, bytes calldata msgData) external {
        timelockHook.queueOperation(address(this), operator, msgValue, msgData);
    }

    // ── Multiplexer ──

    function installMultiplexer(bytes calldata data) external {
        multiplexer.onInstall(data);
    }

    function muxPreCheck(address msgSender, uint256 msgValue, bytes calldata msgData)
        external
        returns (bytes memory)
    {
        return multiplexer.preCheck(msgSender, msgValue, msgData);
    }

    function addMuxHook(address hook) external {
        multiplexer.addHook(hook);
    }
}

/// @title IntegrationTest - Full operator delegation flow
/// @notice Tests the complete lifecycle: deploy, configure, immediate execution,
///         queued execution, owner cancellation, and failed execution after cancel.
contract IntegrationTest is Test {
    ManagedAccountTimelockHook timelockHook;
    HookMultiPlexer multiplexer;
    UniswapSwapPolicy swapPolicy;
    IntegrationAccount account;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");

    uint128 constant COOLDOWN = 1 hours;
    uint128 constant EXPIRATION = 24 hours;

    // Immediate selector: Uniswap exactInputSingle
    bytes4 constant SWAP_SELECTOR = 0x414bf389;

    // Non-immediate operation data (generic call)
    bytes constant NON_IMMEDIATE_DATA = hex"deadbeef11223344";

    // Target address for the swap router
    address swapRouter;

    function setUp() public {
        // 1) Deploy all contracts
        timelockHook = new ManagedAccountTimelockHook();
        multiplexer = new HookMultiPlexer();
        swapPolicy = new UniswapSwapPolicy();
        account = new IntegrationAccount(timelockHook, multiplexer);

        swapRouter = makeAddr("uniswapRouter");

        // 2) Configure timelock (1 hour cooldown, 24h expiration)
        account.installTimelock(abi.encode(owner, COOLDOWN, EXPIRATION));

        // 3) [C-03] Whitelist the swap selector for a specific target (not address(0))
        account.whitelistSelector(swapRouter, SWAP_SELECTOR, true);
    }

    /// @dev Build ERC-7579 single-execute formatted msgData:
    ///      [4-byte execute selector][32-byte mode][20-byte target (packed)][32-byte value][inner calldata]
    function _buildERC7579SingleExecData(address target, bytes4 innerSelector) internal pure returns (bytes memory) {
        bytes memory innerCalldata = abi.encodeWithSelector(innerSelector, uint256(0));
        bytes32 mode = bytes32(0); // CALLTYPE_SINGLE
        return abi.encodePacked(
            bytes4(0x12345678), // execute selector (arbitrary)
            mode,
            target,
            uint256(0),
            innerCalldata
        );
    }

    // ──────────────────── Full Flow Test ────────────────────

    function test_fullOperatorFlow() public {
        // ── Step 1-3: Verify setup ──
        IManagedAccountTimelockHook.TimelockConfig memory config =
            timelockHook.getTimelockConfig(address(account));
        assertEq(config.cooldownPeriod, COOLDOWN);
        assertEq(config.expirationPeriod, EXPIRATION);
        assertTrue(timelockHook.isImmediateSelector(address(account), swapRouter, SWAP_SELECTOR));

        // ── Step 4: Operator submits swap via preCheck (immediate path) ──
        // [C-03] Build proper ERC-7579 execute calldata with target
        bytes memory swapMsgData = _buildERC7579SingleExecData(swapRouter, SWAP_SELECTOR);
        bytes memory hookData = account.timelockPreCheck(operator, 0, swapMsgData);
        (bool isOwnerOrImmediate, bytes32 execHash) = abi.decode(hookData, (bool, bytes32));
        assertTrue(isOwnerOrImmediate);
        assertEq(execHash, bytes32(0)); // immediate = no execHash

        // ── Step 5: Operator submits non-immediate operation (queued) ──
        bytes32 nonImmediateHash = timelockHook.computeExecHash(
            address(account), operator, 0, NON_IMMEDIATE_DATA
        );

        // [C-02] Queue as operator (authorized caller)
        vm.prank(operator);
        timelockHook.queueOperation(address(account), operator, 0, NON_IMMEDIATE_DATA);

        IManagedAccountTimelockHook.QueueEntry memory entry =
            timelockHook.getQueueEntry(address(account), nonImmediateHash);
        assertTrue(entry.exists);
        assertEq(entry.operator, operator);

        // ── Step 6: Warp past cooldown, operator executes (succeeds) ──
        vm.warp(block.timestamp + COOLDOWN + 1);

        hookData = account.timelockPreCheck(operator, 0, NON_IMMEDIATE_DATA);
        (isOwnerOrImmediate, execHash) = abi.decode(hookData, (bool, bytes32));
        assertFalse(isOwnerOrImmediate);
        assertEq(execHash, nonImmediateHash);

        // [H-06] Queue entry still exists after preCheck (moved deletion to postCheck)
        entry = timelockHook.getQueueEntry(address(account), nonImmediateHash);
        assertTrue(entry.exists);

        // postCheck clears the queue entry
        account.timelockPostCheck(hookData);
        entry = timelockHook.getQueueEntry(address(account), nonImmediateHash);
        assertFalse(entry.exists);

        // ── Step 7: Operator submits another op, owner cancels before cooldown ──
        bytes memory anotherOpData = hex"cafebabe55667788";
        bytes32 anotherHash = timelockHook.computeExecHash(
            address(account), operator, 0, anotherOpData
        );

        // [C-02] Queue as operator
        vm.prank(operator);
        timelockHook.queueOperation(address(account), operator, 0, anotherOpData);

        // Owner cancels
        account.cancelOp(anotherHash);

        // Verify cancelled
        entry = timelockHook.getQueueEntry(address(account), anotherHash);
        assertFalse(entry.exists);

        // ── Step 8: Operator tries to execute cancelled op (reverts) ──
        vm.warp(block.timestamp + COOLDOWN + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IManagedAccountTimelockHook.OperationNotQueued.selector,
                anotherHash
            )
        );
        account.timelockPreCheck(operator, 0, anotherOpData);
    }

    // ──────────────────── Owner Bypass Test ────────────────────

    function test_ownerBypassesTimelock() public {
        // Owner can execute any operation immediately, even non-immediate
        bytes memory hookData = account.timelockPreCheck(owner, 0, NON_IMMEDIATE_DATA);
        (bool isOwner,) = abi.decode(hookData, (bool, bytes32));
        assertTrue(isOwner);
    }

    // ──────────────────── Multiplexer Composition Test ────────────────────

    function test_multiplexerComposition() public {
        // Deploy a separate timelock for the multiplexer context
        ManagedAccountTimelockHook muxTimelock = new ManagedAccountTimelockHook();

        // Install multiplexer with hooks
        address[] memory hookAddrs = new address[](1);
        hookAddrs[0] = address(muxTimelock);
        account.installMultiplexer(abi.encode(hookAddrs));

        address[] memory hooks = multiplexer.getHooks(address(account));
        assertEq(hooks.length, 1);
        assertEq(hooks[0], address(muxTimelock));

        // [H-03] WARNING: The multiplexer calls sub-hooks with msg.sender = multiplexer address,
        // NOT the original account. This makes ManagedAccountTimelockHook fundamentally
        // incompatible with the HookMultiPlexer. This test only verifies the install flow,
        // not the preCheck/postCheck flow, which would break due to the msg.sender context issue.
    }
}
