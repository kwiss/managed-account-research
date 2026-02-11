// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC7579Hook} from "../interfaces/IERC7579Hook.sol";
import {IModule} from "../interfaces/IERC7579Module.sol";
import {IManagedAccountTimelockHook} from "./IManagedAccountTimelockHook.sol";
import {ISafe} from "../interfaces/ISafe.sol";
import {MODULE_TYPE_HOOK} from "../types/ModuleType.sol";

/// @title ManagedAccountTimelockHook
/// @notice ERC-7579 Hook that enforces time-delayed execution for non-owner operations
/// @dev Portable across architectures — identical contract works with Safe+Zodiac (A), Safe+7579 (B), or Kernel (C)
///
/// Flow:
///   1. Owner calls -> bypass (immediate execution)
///   2. Operator calls with immediate selector -> bypass
///   3. Operator must first call queueOperation() to queue an operation
///   4. After cooldown, operator calls execute on the account -- preCheck allows it
///   5. Owner can CANCEL any queued operation before execution
contract ManagedAccountTimelockHook is IERC7579Hook, IManagedAccountTimelockHook {
    // ─── Constants ───────────────────────────────────────────────────────────

    /// @dev Minimum cooldown to prevent trivial timestamp manipulation bypass
    uint256 public constant MIN_COOLDOWN = 5 minutes;

    // ─── Storage ─────────────────────────────────────────────────────────────

    /// @dev account => TimelockConfig
    mapping(address => TimelockConfig) private _configs;

    /// @dev account => operationHash => QueuedOperation
    mapping(address => mapping(bytes32 => QueuedOperation)) private _queue;

    /// @dev account => target => selector => isImmediate
    mapping(address => mapping(address => mapping(bytes4 => bool))) private _immediateSelectors;

    // ─── ERC-7579 Module Lifecycle ───────────────────────────────────────────

    /// @inheritdoc IModule
    function onInstall(bytes calldata data) external override {
        (uint256 cooldown, uint256 expiration) = abi.decode(data, (uint256, uint256));
        if (cooldown < MIN_COOLDOWN || expiration == 0) revert InvalidTimelockConfig();

        // Use msg.sender as safeAccount — the Safe7579 adapter calls onInstall with msg.sender = Safe address
        // This avoids the need to pass safeAccount as a parameter and prevents address(0) misconfiguration (H-02, M-05)
        _configs[msg.sender] = TimelockConfig({
            cooldown: cooldown,
            expiration: expiration,
            safeAccount: msg.sender,
            generation: _configs[msg.sender].generation // preserve generation across reinstalls
        });

        emit TimelockConfigSet(msg.sender, cooldown, expiration);
    }

    /// @inheritdoc IModule
    function onUninstall(bytes calldata) external override {
        // Increment generation to invalidate all stale queue entries and immediate selectors (M-06)
        uint256 nextGen = _configs[msg.sender].generation + 1;
        delete _configs[msg.sender];
        // Store the incremented generation so reinstallation uses a fresh generation
        _configs[msg.sender].generation = nextGen;
    }

    /// @inheritdoc IModule
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_HOOK;
    }

    // ─── Queue Operation ─────────────────────────────────────────────────────

    /// @notice Queue an operation for time-delayed execution
    /// @dev Only the account itself or the specified operator can queue (C-01 fix)
    /// @param account The account address (Safe) this operation belongs to
    /// @param operator The operator who will execute the operation
    /// @param msgData The full execution calldata that will be passed to the account
    function queueOperation(address account, address operator, bytes calldata msgData) external {
        // C-01: Access control — only the account or the operator can queue
        if (msg.sender != account && msg.sender != operator) revert UnauthorizedCaller();

        TimelockConfig storage config = _configs[account];
        if (config.safeAccount == address(0)) revert NotInitialized();

        // H-03: Use abi.encode instead of abi.encodePacked to prevent hash collisions
        bytes32 opHash = keccak256(abi.encode(account, operator, msgData));

        QueuedOperation storage op = _queue[account][opHash];
        // Check that operation is not already queued (must be unconsumed and from current generation)
        if (op.queuedAt != 0 && !op.consumed && op.generation == config.generation) {
            revert OperationAlreadyQueued(opHash);
        }

        op.queuedAt = block.timestamp;
        op.consumed = false;
        op.generation = config.generation;

        emit OperationQueued(account, opHash, block.timestamp);
    }

    // ─── Hook Logic ──────────────────────────────────────────────────────────

    /// @inheritdoc IERC7579Hook
    function preCheck(address msgSender, uint256, bytes calldata msgData)
        external
        override
        returns (bytes memory hookData)
    {
        TimelockConfig storage config = _configs[msg.sender];
        if (config.safeAccount == address(0)) revert NotInitialized();

        // 1. Owner bypass — owners can execute immediately
        if (ISafe(config.safeAccount).isOwner(msgSender)) {
            return abi.encode(false); // no postCheck needed
        }

        // 2. Check execution mode — only single execution (mode = bytes32(0)) is supported (H-06)
        if (msgData.length >= 36) {
            bytes32 mode = bytes32(msgData[4:36]);
            if (mode != bytes32(0)) revert UnsupportedExecutionMode();
        }

        // 3. Extract target and selector from execution calldata
        (address target, bytes4 selector) = _extractTargetAndSelector(msgData);

        // 4. Immediate selector bypass
        if (_immediateSelectors[msg.sender][target][selector]) {
            return abi.encode(false);
        }

        // 5. Compute operation hash (H-03: use abi.encode)
        bytes32 opHash = keccak256(abi.encode(msg.sender, msgSender, msgData));

        QueuedOperation storage op = _queue[msg.sender][opHash];

        // 6. Must be queued and from current generation
        if (op.queuedAt == 0 || op.consumed || op.generation != config.generation) {
            revert OperationNotFound(opHash);
        }

        // 7. Check cooldown
        uint256 readyAt = op.queuedAt + config.cooldown;
        if (block.timestamp < readyAt) {
            revert OperationNotReady(opHash, readyAt);
        }

        // 8. Check expiration
        uint256 expiresAt = readyAt + config.expiration;
        if (block.timestamp > expiresAt) {
            op.consumed = true; // mark as consumed to prevent replay
            revert OperationExpired(opHash, expiresAt);
        }

        // 9. Mark as consumed and allow execution
        op.consumed = true;
        emit OperationExecuted(msg.sender, opHash);

        return abi.encode(true);
    }

    /// @inheritdoc IERC7579Hook
    function postCheck(bytes calldata hookData) external pure override {
        // No post-execution checks needed for timelock
        (hookData);
    }

    // ─── Owner Functions ─────────────────────────────────────────────────────

    /// @inheritdoc IManagedAccountTimelockHook
    /// @dev C-02 fix: requires msgSender parameter and verifies caller is a Safe owner
    function cancelExecution(address msgSender, bytes32 operationHash) external override {
        TimelockConfig storage config = _configs[msg.sender];
        if (config.safeAccount == address(0)) revert NotInitialized();

        // C-02: Verify the original caller is a Safe owner
        if (!ISafe(config.safeAccount).isOwner(msgSender)) revert OnlyOwner();

        QueuedOperation storage op = _queue[msg.sender][operationHash];
        if (op.queuedAt == 0 || op.consumed || op.generation != config.generation) {
            revert OperationNotFound(operationHash);
        }

        op.consumed = true;
        emit OperationCancelled(msg.sender, operationHash);
    }

    /// @inheritdoc IManagedAccountTimelockHook
    function setTimelockConfig(uint256 cooldown, uint256 expiration) external override {
        // M-02: Enforce minimum cooldown
        if (cooldown < MIN_COOLDOWN) revert CooldownTooShort();
        if (expiration == 0) revert InvalidTimelockConfig();

        TimelockConfig storage config = _configs[msg.sender];
        if (config.safeAccount == address(0)) revert NotInitialized();

        config.cooldown = cooldown;
        config.expiration = expiration;

        emit TimelockConfigSet(msg.sender, cooldown, expiration);
    }

    /// @inheritdoc IManagedAccountTimelockHook
    function setImmediateSelector(address target, bytes4 selector, bool allowed) external override {
        TimelockConfig storage config = _configs[msg.sender];
        if (config.safeAccount == address(0)) revert NotInitialized();

        _immediateSelectors[msg.sender][target][selector] = allowed;

        emit ImmediateSelectorSet(msg.sender, target, selector, allowed);
    }

    // ─── View Functions ──────────────────────────────────────────────────────

    /// @inheritdoc IManagedAccountTimelockHook
    function getTimelockConfig(address account) external view override returns (TimelockConfig memory) {
        return _configs[account];
    }

    /// @inheritdoc IManagedAccountTimelockHook
    function getQueuedOperation(address account, bytes32 operationHash)
        external
        view
        override
        returns (QueuedOperation memory)
    {
        return _queue[account][operationHash];
    }

    /// @inheritdoc IManagedAccountTimelockHook
    function isImmediateSelector(address account, address target, bytes4 selector)
        external
        view
        override
        returns (bool)
    {
        return _immediateSelectors[account][target][selector];
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    /// @dev Extracts target address and function selector from execution calldata
    /// @param msgData The full calldata passed to the account
    /// @return target The target address of the execution
    /// @return selector The function selector being called
    function _extractTargetAndSelector(bytes calldata msgData)
        internal
        pure
        returns (address target, bytes4 selector)
    {
        // msgData format for ERC-7579 execute:
        // [0:4]   = execute selector
        // [4:36]  = mode (bytes32)
        // [36:68] = offset to executionCalldata
        // Then executionCalldata = abi.encodePacked(target, value, callData) as bytes

        // M-01: Revert instead of returning defaults for malformed calldata
        if (msgData.length < 100) {
            revert InvalidExecutionCalldata();
        }

        // Skip selector(4) + mode(32) = 36, then read offset(32)
        uint256 offset = uint256(bytes32(msgData[36:68]));
        uint256 dataStart = 4 + offset; // 4 for selector

        if (msgData.length < dataStart + 32) {
            revert InvalidExecutionCalldata();
        }

        // Read length of bytes param
        uint256 dataLen = uint256(bytes32(msgData[dataStart:dataStart + 32]));
        uint256 encodedStart = dataStart + 32;

        if (msgData.length < encodedStart + 52) {
            revert InvalidExecutionCalldata();
        }

        // For single execution mode, the executionCalldata is:
        // abi.encodePacked(address target (20 bytes), uint256 value (32 bytes), bytes callData)
        target = address(bytes20(msgData[encodedStart:encodedStart + 20]));

        // callData starts at encodedStart + 20 + 32 = encodedStart + 52
        if (dataLen > 52) {
            selector = bytes4(msgData[encodedStart + 52:encodedStart + 56]);
        }
    }
}
